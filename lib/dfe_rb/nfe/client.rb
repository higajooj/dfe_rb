module DfeRb
  module Nfe
    # The entry point for emitting NF-e with a certificate.
    #
    #   client = DfeRb::Nfe::Client.new(certificate: cert, uf: "SP")   # homologação by default
    #   client.status.online?
    #   signed = client.sign(invoice)          # store signed.xml before sending
    #   result = client.authorize(signed)
    #   File.write("#{result.key}-procNFe.xml", result.proc_xml) if result.authorized?
    #   result = client.resume(result.receipt, [result]) if result.pending?   # lot answer still pending
    class Client
      MAX_LOT = 50
      DEFAULT_POLLING = {wait: 15, interval: 5, max_wait: 120}.freeze

      attr_reader :certificate, :uf, :environment, :transport

      # certificate: a DfeRb::Certificate.
      # uf:          the issuer's state; picks the SEFAZ that authorizes its notes.
      # environment: :homologacao (default, no fiscal value) or :production.
      # endpoints:   URL overrides per service, e.g. {authorization: "https://..."}.
      # transport:   anything with #post(endpoint, xml); defaults to the mTLS SOAP client.
      # technical_contact: the software house's infRespTec for every invoice built here
      #              ({cnpj:, contact:, email:, phone:, csrt_id:, csrt:}); see Invoice.
      def initialize(certificate:, uf:, environment: Environment::HOMOLOGACAO, endpoints: {}, transport: nil,
        timeouts: {}, logger: nil, clock: Time, sleeper: Kernel.method(:sleep), technical_contact: nil)
        @certificate = certificate
        @uf = States.abbreviation(uf)
        @environment = Environment.normalize(environment)
        @endpoints = endpoints
        @transport = transport || Transport.new(certificate: certificate, timeouts: timeouts, logger: logger)
        @clock = clock
        @sleeper = sleeper
        @technical_contact = technical_contact
      end

      def production? = environment == Environment::PRODUCTION

      # A new invoice for this client's environment. Fill it with a block and/or a hash.
      def build_invoice(attributes = nil, **fields, &block)
        Invoice.new(attributes, environment: environment, clock: @clock, technical_contact: @technical_contact, **fields, &block)
      end

      # Asks whether the authorizer is up (cStat 107). With `contingency: true` it asks the
      # state's SVC, which is online only while the state's SEFAZ has it activated (113 and 114
      # otherwise).
      def status(uf: self.uf, contingency: false)
        response = Response.new(call(:status, Requests.status(state: uf, environment: environment), uf: uf, contingency: contingency))
        StatusResult.new(code: response.code, message: response.message, state_code: response.text("cUF"),
          received_at: response.text("dhRecbto"), average_seconds: response.text("tMed")&.to_i, xml: response.xml)
      end

      # Validates and signs an Invoice, or raw <NFe> XML (signed or not). Returns a
      # SignedInvoice. Store its `xml` before sending, so a lost answer can be resolved later.
      #
      # Raw XML gets the same schema and business-rule checks as an Invoice. A SignedInvoice
      # (or one restored from storage) isn't validated again, but like any input it must be
      # for this client's environment, belong to the certificate's company and carry a
      # signature that verifies.
      #
      # `strict: false` skips the business-rule checks. The schema and value formats are
      # always enforced.
      def sign(input, strict: true)
        document = case input
        when Invoice then Document.new(input.to_xml(strict: strict))
        when SignedInvoice then Document.new(input.xml)
        else validated(Document.new(input), strict: strict)
        end
        check_environment(document)
        check_certificate(document)

        signed = document.signed? ? document.xml : Signature.sign_nfe(document.xml, certificate)
        problem = Signature.verify(signed)
        raise ValidationError, ["the signature does not verify: #{problem}"] unless problem == true

        result = SignedInvoice.new(xml: signed, key: document.key, digest_value: Signature.digest_value(signed))
        (result == input) ? input : result
      end

      # Sends one NF-e synchronously, or up to 50 as an asynchronous lot. Accepts Invoices,
      # SignedInvoices or raw XML. Returns an AuthorizationResult, or an Array of them when
      # given an Array.
      #
      # When the answer is lost (a timeout, say) or SEFAZ reports the key as a duplicate, it
      # looks the key up. If the stored note is this same document, it returns that note's
      # protocol (`result.recovered?` is true) instead of raising.
      #
      # If polling a lot times out or fails, the results come back pending and carry the
      # receipt. Finish them with #resume.
      #
      # Notes issued in SVC contingency (tpEmis 6 or 7) go to the state's SVC, and so do
      # #resume, #consult and #cancel for them.
      def authorize(input, lot_id: nil, recover: true, polling: {}, strict: true)
        many = input.is_a?(Array)
        signed = Array(input).map { |item| sign(item, strict: strict) }
        raise ArgumentError, "nothing to authorize" if signed.empty?
        raise ArgumentError, "a lot holds at most #{MAX_LOT} notes (got #{signed.size})" if signed.size > MAX_LOT

        results = transmit(signed, lot_id: lot_id || new_lot_id, recover: recover, polling: DEFAULT_POLLING.merge(polling))
        many ? results : results.first
      end

      # Collects the answer to an asynchronous lot SEFAZ already accepted (cStat 103). Takes
      # the receipt and the notes sent in the lot, as SignedInvoices or as the pending
      # AuthorizationResults #authorize returned. Returns results as #authorize does.
      def resume(receipt, notes, recover: true, polling: {})
        many = notes.is_a?(Array)
        signed = Array(notes).map do |note|
          next sign(note) unless note.is_a?(AuthorizationResult)

          sign(SignedInvoice.new(xml: note.signed_xml, key: note.key, digest_value: Signature.digest_value(note.signed_xml)))
        end
        raise ArgumentError, "nothing to resume" if signed.empty?

        results = collect_lot(signed, receipt.to_s, DEFAULT_POLLING.merge(wait: 0).merge(polling), recover)
        many ? results : results.first
      end

      # Like #authorize, but raises Rejected, Denied or ConsumptionBlocked unless authorized.
      def authorize!(input, **options)
        outcome = authorize(input, **options)
        Array(outcome).each do |result|
          next if result.authorized?

          raise ConsumptionBlocked, result if result.blocked?
          raise Denied, result if result.denied?
          raise Rejected, result
        end
        outcome
      end

      # Where a key stands at SEFAZ. Asks the key's own state, or its SVC for a key issued
      # there. `via: :home` or `via: :contingency` picks the authorizer yourself.
      def consult(key, via: nil)
        key = AccessKey.parse(key.to_s)
        response = Response.new(call(:consult, Requests.consult(key: key, environment: environment), uf: key.state,
          contingency: contingency?(key, via)))
        protocol_xml = response.fragment("protNFe")
        protocol = protocol_xml && Protocol.parse(protocol_xml)

        ConsultResult.new(
          key: key.to_s, code: response.code, message: response.message,
          protocol: protocol&.number, received_at: protocol&.received_at || response.text("dhRecbto"),
          digest_value: protocol&.digest_value, events: consult_events(response), protocol_xml: protocol_xml, xml: response.xml
        )
      end

      # Cancels an authorized note (evento 110111). `protocol` is the authorization protocol.
      # Allowed for 24 hours after authorization unless the state allows longer. A note the
      # SVC authorized is canceled there (Anexo III 2.1.3.4 c); `via:` overrides it.
      def cancel(key, protocol:, reason:, via: nil)
        key = AccessKey.parse(key.to_s)
        protocol = protocol.to_s.strip
        raise ArgumentError, "protocol must have 15 or 17 digits" unless protocol.match?(/\A(\d{15}|\d{17})\z/)

        detail = Requests.cancellation_detail(protocol: protocol, reason: justification(reason, "reason", 15..255))
        send_event(key, "110111", 1, detail, contingency: contingency?(key, via))
      end

      # Corrects an authorized note (Carta de Correção, evento 110110). A new correction
      # replaces the previous one; `sequence` counts them (1..20). It goes to the state's own
      # authorizer, since the SVC takes no CC-e, unless you pass `via: :contingency`.
      def correct(key, text:, sequence: 1, via: :home)
        key = AccessKey.parse(key.to_s)
        raise ArgumentError, "sequence must be between 1 and 20" unless (1..20).cover?(sequence)

        detail = Requests.correction_detail(text: justification(text, "text", 15..1000))
        send_event(key, "110110", sequence, detail, contingency: contingency?(key, via))
      end

      # Declares a range of numbers as unused (inutilização).
      def inutilize(series:, from:, reason:, to: from, model: 55, year: @clock.now.year)
        raise ArgumentError, "from must not be greater than to" if from > to
        raise ArgumentError, "a request covers at most 10000 numbers" if to - from >= 10_000

        unsigned = Requests.inutilization(state: uf, year: year, tax_id: certificate.tax_id, model: model, series: series,
          from: from, to: to, reason: justification(reason, "reason", 15..255), environment: environment)
        signed = Signature.sign_inutilization(unsigned, certificate)

        response = Response.new(call(:inutilization, signed))
        InutilizationResult.new(code: response.code, message: response.message, protocol: response.text("nProt"),
          request_xml: signed, return_xml: response.fragment("retInutNFe"), xml: response.xml)
      end

      # Sends `xml` to a service as is and returns the answer's XML. Use it for anything the
      # client doesn't wrap. `service` is :status, :authorization, :authorization_return,
      # :consult, :inutilization or :event.
      def raw(service, xml, uf: self.uf, contingency: false)
        call(service, xml, uf: uf, contingency: contingency)
      end

      def endpoint(service, uf: self.uf, contingency: false)
        Endpoints.resolve(uf: uf, environment: environment, service: service, overrides: @endpoints, contingency: contingency)
      end

      # Registers the Evento Prévio de Emissão em Contingência (110140) at the Ambiente
      # Nacional, for a note issued with `contingency :epec` (tpEmis 4). Once it is registered,
      # the DANFE can be printed and the note can travel. When the state's SEFAZ is back, send
      # the same signed note with #authorize. Takes what #sign takes, or the event
      # #prepare_epec returned.
      def epec(input)
        event = input.is_a?(SignedEpec) ? input : prepare_epec(input)
        key = AccessKey.parse(event.key)
        overrides = {manifestation: @endpoints[:epec]}.compact
        endpoint = Distribution::Endpoints.resolve(service: :manifestation, environment: environment, overrides: overrides)
        register_event(key, Epec::TYPE, 1, event.xml, endpoint)
      end

      # The signed EPEC of a note. Store it before sending it, so an answer lost on the way
      # can be resolved with the same event.
      def prepare_epec(input)
        note = sign(input)
        unsigned = Epec.build(Document.new(note.xml), environment: environment, clock: @clock)
        SignedEpec.new(xml: Signature.sign_event(unsigned, certificate), key: note.key)
      end

      # The registrations of a taxpayer in a state's ICMS cadastro (NfeConsultaCadastro), by
      # CNPJ, CPF or IE. `uf` is the state consulted. It answers for its own taxpayers to any
      # NF-e issuer (RV K01). States without the service raise Unsupported.
      def taxpayers(uf:, cnpj: nil, cpf: nil, ie: nil)
        state = States.abbreviation(uf)
        request = Requests.registry(state: state, cnpj: cnpj, cpf: cpf, ie: ie)
        problems = Distribution::Schemas.issues(request, package: "cad_2.00", file: "consCad_v2.00.xsd")
        raise ValidationError, problems unless problems.empty?

        endpoint = Endpoints.registry(uf: state, environment: environment, overrides: @endpoints)
        Registry.parse(transport.post(endpoint, request), request_xml: request)
      end

      private

      def call(service, xml, uf: self.uf, contingency: false)
        transport.post(endpoint(service, uf: uf, contingency: contingency), xml)
      end

      # Whether a request about `key` goes to the SVC. It follows the key's tpEmis (6 or 7)
      # unless `via` names the authorizer.
      def contingency?(key, via)
        case via
        when nil then States::SVC_EMISSION_TYPES.value?(AccessKey.parse(key.to_s).emission_type)
        when :contingency then true
        when :home then false
        else raise ArgumentError, "via must be :home or :contingency (got #{via.inspect})"
        end
      end

      # A lot goes to one authorizer, so notes for the SVC can't share a lot with the others.
      def contingency_lot?(signed)
        kinds = signed.map { |note| contingency?(note.key, nil) }.uniq
        raise ArgumentError, "a lot can't mix notes issued for the SVC (tpEmis 6 or 7) with others" if kinds.size > 1

        kinds.first
      end

      def new_lot_id = (@clock.now.to_f * 1000).to_i.to_s

      # Checks the schema, and the business rules unless `strict: false`, for XML that didn't
      # come from an Invoice.
      def validated(document, strict:)
        problems = Schemas.nfe_issues(document.xml)
        problems += Validator.new(document.to_infnfe).issues if strict && problems.empty?
        raise ValidationError, problems unless problems.empty?

        document
      end

      def check_environment(document)
        declared = document.environment
        return if declared.nil? || declared == Environment.code(environment)

        raise ValidationError, ["the NFe was built for #{(declared == "1") ? "production" : "homologacao"} " \
          "but this client talks to #{environment}"]
      end

      # The certificate must be valid and belong to the issuer's company (same CNPJ root).
      def check_certificate(document)
        problems = []
        problems << "the certificate expired on #{certificate.expires_at.utc.iso8601}" if certificate.expired?
        problems << "the certificate is not valid yet (starts #{certificate.not_before.utc.iso8601})" if certificate.not_before > @clock.now

        issuer = document.issuer_cnpj
        issuer_cpf = document.issuer_cpf
        if issuer && certificate.cnpj_root && issuer[0, 8] != certificate.cnpj_root
          problems << "the certificate belongs to CNPJ root #{certificate.cnpj_root} but the issuer is #{issuer} (rej. 213)"
        elsif issuer_cpf && certificate.cpf && issuer_cpf != certificate.cpf
          problems << "the certificate belongs to CPF #{certificate.cpf} but the issuer is #{issuer_cpf} (rej. 227)"
        end
        raise ValidationError, problems unless problems.empty?
      end

      def justification(text, name, range)
        clean = Formatter.sanitize(text)
        raise ArgumentError, "#{name} must have #{range.min} to #{range.max} characters (got #{clean.length})" unless range.cover?(clean.length)

        clean
      end

      def transmit(signed, lot_id:, recover:, polling:)
        sync = signed.size == 1
        lot = begin
          Response.new(call(:authorization, Requests.authorization(signed.map(&:xml), lot_id: lot_id, sync: sync),
            contingency: contingency_lot?(signed)))
        rescue TransportError => e
          raise unless recover && e.maybe_processed?

          # If the lookup fails too, the first error stands. The note may have been processed,
          # whatever the lookup's own failure says.
          return signed.map { |note| recovered_quietly(note, e) || raise(e) }
        end

        receipt = lot.text("nRec")
        return collect_lot(signed, receipt, polling, recover) if !sync && lot.code == StatusCodes::BATCH_RECEIVED

        protocol_xml = sync && lot.fragment("protNFe")
        protocols = protocol_xml ? [Protocol.parse(protocol_xml)] : []
        signed.map { |note| result_for(note, lot, protocols, receipt, recover) }
      end

      # Polls an accepted lot and matches its protocols to the notes. If polling fails, each
      # note is looked up by key (with `recover`) and the ones still unknown come back pending
      # with the receipt, to finish with #resume.
      def collect_lot(signed, receipt, polling, recover)
        answer = begin
          wait_for_lot(receipt, polling, contingency_lot?(signed))
        rescue TransportError => e
          return signed.map { |note| (recover && recovered_quietly(note, e)) || pending(note, receipt, e) }
        end

        protocols = answer.fragments("protNFe").map { |xml| Protocol.parse(xml) }
        signed.map { |note| result_for(note, answer, protocols, receipt, recover) }
      end

      def pending(note, receipt, cause)
        build_result(note, StatusCodes::BATCH_RECEIVED, "Lote recebido; resultado pendente (#{cause.message})", nil, receipt, nil)
      end

      # Like #recovered, but returns nil when the lookup fails too, which leaves the note pending.
      def recovered_quietly(note, cause)
        recovered(note, cause: cause)
      rescue TransportError
        nil
      end

      # Polls the lot until SEFAZ has processed it (cStat 104) or `max_wait` seconds have passed.
      def wait_for_lot(receipt, polling, contingency)
        @sleeper.call(polling[:wait])
        waited = polling[:wait]
        loop do
          answer = Response.new(call(:authorization_return, Requests.lot_return(receipt: receipt, environment: environment),
            contingency: contingency))
          return answer unless answer.code == StatusCodes::BATCH_PROCESSING && waited < polling[:max_wait]

          @sleeper.call(polling[:interval])
          waited += polling[:interval]
        end
      end

      def result_for(note, answer, protocols, receipt, recover)
        protocol = protocols.find { |candidate| candidate.key == note.key }
        unless protocol
          # An expired receipt (cStat 106) says nothing about the notes: ask for each key.
          found = recover && answer.code == StatusCodes::BATCH_NOT_FOUND && recovered_quietly(note, answer)
          return found || build_result(note, answer.code, answer.message, nil, receipt, answer.xml)
        end

        if recover && StatusCodes.duplicate?(protocol.code)
          found = recovered(note, cause: protocol)
          return found if found
        end
        build_result(note, protocol.code, protocol.message, protocol, receipt, answer.xml)
      end

      def build_result(note, code, message, protocol, receipt, response_xml, recovered: false)
        AuthorizationResult.new(
          key: note.key, code: code, message: message, protocol: protocol&.number, received_at: protocol&.received_at,
          alerts: protocol&.alerts || [], digest_value: protocol&.digest_value, signed_xml: note.xml,
          protocol_xml: protocol&.xml, response_xml: response_xml, receipt: receipt, recovered: recovered
        )
      end

      # Looks the key up after a lost answer or a duplicate report. Returns the result when SEFAZ
      # holds this very document, nil when it holds nothing (safe to send again), and raises
      # Conflict when it holds a different one. A note canceled since keeps its authorization
      # protocol but reports the consult's status (101...), so it is never taken as usable.
      def recovered(note, cause:)
        found = consult(note.key)
        return unless found.found? && found.protocol_xml

        if found.digest_value == note.digest_value
          protocol = Protocol.parse(found.protocol_xml)
          code, message = found.canceled? ? [found.code, found.message] : [protocol.code, protocol.message]
          build_result(note, code, message, protocol, nil, found.xml, recovered: true)
        else
          raise Conflict, "SEFAZ already holds #{note.key} with different content (#{found.code} #{found.message}); " \
            "the note being sent differs from the stored one. (#{cause.message})"
        end
      end

      def consult_events(response)
        response.plain.xpath("//procEventoNFe").map do |node|
          fragment = Response.new(node.to_xml)
          EventSummary.new(
            type: fragment.text("tpEvento"), sequence: fragment.text("nSeqEvento")&.to_i,
            code: fragment.text("retEvento/infEvento/cStat")&.to_i, message: fragment.text("retEvento/infEvento/xMotivo"),
            protocol: fragment.text("retEvento/infEvento/nProt"), description: fragment.text("descEvento"), xml: node.to_xml
          )
        end
      end

      def send_event(key, type, sequence, detail, contingency: false)
        unsigned = Requests.event(key: key, type: type, sequence: sequence, detail: detail, environment: environment,
          at: States.now(key.state, @clock))
        signed = Signature.sign_event(unsigned, certificate)
        register_event(key, type, sequence, signed, endpoint(:event, uf: key.state, contingency: contingency))
      end

      def register_event(key, type, sequence, signed, endpoint)
        response = Response.new(transport.post(endpoint, Requests.event_batch([signed], lot_id: new_lot_id)))

        registered = response.plain.xpath("//retEvento").first
        detail = registered && Response.new(registered.to_xml)
        namespaced = response.fragment("retEvento")
        EventResult.new(
          key: key.to_s, type: type, sequence: sequence,
          code: (detail || response).code, message: (detail || response).message, protocol: detail&.text("nProt"),
          event_xml: signed, return_xml: namespaced, xml: response.xml
        )
      end
    end
  end
end
