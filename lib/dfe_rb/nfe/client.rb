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
      def initialize(certificate:, uf:, environment: Environment::HOMOLOGACAO, endpoints: {}, transport: nil,
        timeouts: {}, logger: nil, clock: Time, sleeper: Kernel.method(:sleep))
        @certificate = certificate
        @uf = States.abbreviation(uf)
        @environment = Environment.normalize(environment)
        @endpoints = endpoints
        @transport = transport || Transport.new(certificate: certificate, timeouts: timeouts, logger: logger)
        @clock = clock
        @sleeper = sleeper
      end

      def production? = environment == Environment::PRODUCTION

      # A new invoice for this client's environment. Fill it with a block and/or a hash.
      def build_invoice(attributes = nil, **fields, &block)
        Invoice.new(attributes, environment: environment, clock: @clock, **fields, &block)
      end

      # Is the authorizer up? (cStat 107)
      def status(uf: self.uf)
        response = Response.new(call(:status, Requests.status(state: uf, environment: environment), uf: uf))
        StatusResult.new(code: response.code, message: response.message, state_code: response.text("cUF"),
          received_at: response.text("dhRecbto"), average_seconds: response.text("tMed")&.to_i, xml: response.xml)
      end

      # Validates and signs an Invoice, or raw <NFe> XML (signed or not). Returns a
      # SignedInvoice whose `xml` must be stored before it is sent, so a lost answer can be
      # resolved later.
      #
      # Raw XML goes through the same schema and business-rule checks as an Invoice. A
      # SignedInvoice (or one restored from storage) is not validated again, but like any
      # input it must be for this client's environment, belong to the certificate's company
      # and carry a signature that verifies.
      #
      # With `strict: false` the local business-rule checks are skipped (the schema and value
      # formats are always enforced).
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

      # Sends one NF-e (synchronously) or up to 50 (as an asynchronous lot). Accepts Invoices,
      # SignedInvoices or raw XML. Returns an AuthorizationResult, or an Array of them when
      # given an Array.
      #
      # If the answer is lost (timeout...) or SEFAZ reports the key as a duplicate, the key is
      # looked up and, when the stored note is this same document, its protocol is returned
      # (result.recovered? is true) instead of an error.
      #
      # A lot whose processing couldn't be awaited (polling timed out or failed) comes back
      # as pending results carrying the receipt: finish it with #resume.
      def authorize(input, lot_id: nil, recover: true, polling: {}, strict: true)
        many = input.is_a?(Array)
        signed = Array(input).map { |item| sign(item, strict: strict) }
        raise ArgumentError, "nothing to authorize" if signed.empty?
        raise ArgumentError, "a lot holds at most #{MAX_LOT} notes (got #{signed.size})" if signed.size > MAX_LOT

        results = transmit(signed, lot_id: lot_id || new_lot_id, recover: recover, polling: DEFAULT_POLLING.merge(polling))
        many ? results : results.first
      end

      # Collects the answer to an asynchronous lot SEFAZ already accepted (cStat 103), given
      # its receipt and the notes sent in it: SignedInvoices, or the pending
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

      # Where a key stands at SEFAZ. Routed to the key's own state.
      def consult(key)
        key = AccessKey.parse(key.to_s)
        response = Response.new(call(:consult, Requests.consult(key: key, environment: environment), uf: key.state))
        protocol_xml = response.fragment("protNFe")
        protocol = protocol_xml && Protocol.parse(protocol_xml)

        ConsultResult.new(
          key: key.to_s, code: response.code, message: response.message,
          protocol: protocol&.number, received_at: protocol&.received_at || response.text("dhRecbto"),
          digest_value: protocol&.digest_value, events: consult_events(response), protocol_xml: protocol_xml, xml: response.xml
        )
      end

      # Cancels an authorized note (evento 110111). `protocol` is the authorization protocol.
      # Allowed for 24 hours after authorization unless the state allows longer.
      def cancel(key, protocol:, reason:)
        key = AccessKey.parse(key.to_s)
        protocol = protocol.to_s.strip
        raise ArgumentError, "protocol must have 15 or 17 digits" unless protocol.match?(/\A(\d{15}|\d{17})\z/)

        detail = Requests.cancellation_detail(protocol: protocol, reason: justification(reason, "reason", 15..255))
        send_event(key, "110111", 1, detail)
      end

      # Corrects an authorized note (Carta de Correção, evento 110110). A new correction
      # replaces the previous one; `sequence` counts them (1..20).
      def correct(key, text:, sequence: 1)
        key = AccessKey.parse(key.to_s)
        raise ArgumentError, "sequence must be between 1 and 20" unless (1..20).cover?(sequence)

        detail = Requests.correction_detail(text: justification(text, "text", 15..1000))
        send_event(key, "110110", sequence, detail)
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

      # Sends `xml` to a service as is and returns the answer's XML: the escape hatch for
      # anything the client doesn't wrap. service: :status, :authorization,
      # :authorization_return, :consult, :inutilization or :event.
      def raw(service, xml, uf: self.uf)
        call(service, xml, uf: uf)
      end

      def endpoint(service, uf: self.uf)
        Endpoints.resolve(uf: uf, environment: environment, service: service, overrides: @endpoints)
      end

      private

      def call(service, xml, uf: self.uf)
        transport.post(endpoint(service, uf: uf), xml)
      end

      def new_lot_id = (@clock.now.to_f * 1000).to_i.to_s

      # Schema and (unless strict: false) business rules for XML that didn't come from an
      # Invoice.
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
          Response.new(call(:authorization, Requests.authorization(signed.map(&:xml), lot_id: lot_id, sync: sync)))
        rescue TransportError => e
          raise unless recover && e.maybe_processed?

          return signed.map { |note| recovered(note, cause: e) || raise(e) }
        end

        receipt = lot.text("nRec")
        return collect_lot(signed, receipt, polling, recover) if !sync && lot.code == StatusCodes::BATCH_RECEIVED

        protocol_xml = sync && lot.fragment("protNFe")
        protocols = protocol_xml ? [Protocol.parse(protocol_xml)] : []
        signed.map { |note| result_for(note, lot, protocols, receipt, recover) }
      end

      # Polls an accepted lot and maps its protocols to the notes. When polling fails the
      # receipt is kept: each note is looked up by key (with `recover`) and whatever is still
      # unknown comes back pending, to be finished with #resume.
      def collect_lot(signed, receipt, polling, recover)
        answer = begin
          wait_for_lot(receipt, polling)
        rescue TransportError => e
          return signed.map { |note| (recover && recovered_quietly(note, e)) || pending(note, receipt, e) }
        end

        protocols = answer.fragments("protNFe").map { |xml| Protocol.parse(xml) }
        signed.map { |note| result_for(note, answer, protocols, receipt, recover) }
      end

      def pending(note, receipt, cause)
        build_result(note, StatusCodes::BATCH_RECEIVED, "Lote recebido; resultado pendente (#{cause.message})", nil, receipt, nil)
      end

      # #recovered, but a lookup that fails too just leaves the note pending.
      def recovered_quietly(note, cause)
        recovered(note, cause: cause)
      rescue TransportError
        nil
      end

      # Polls the lot until SEFAZ has processed it (cStat 104) or `max_wait` seconds passed.
      def wait_for_lot(receipt, polling)
        @sleeper.call(polling[:wait])
        waited = polling[:wait]
        loop do
          answer = Response.new(call(:authorization_return, Requests.lot_return(receipt: receipt, environment: environment)))
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

      def send_event(key, type, sequence, detail)
        unsigned = Requests.event(key: key, type: type, sequence: sequence, detail: detail, environment: environment,
          at: States.now(key.state, @clock))
        signed = Signature.sign_event(unsigned, certificate)
        response = Response.new(call(:event, Requests.event_batch([signed], lot_id: new_lot_id), uf: key.state))

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
