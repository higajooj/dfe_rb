module DfeRb
  module Nfe
    # The entry point for emitting NF-e with a certificate.
    #
    #   client = DfeRb::Nfe::Client.new(certificate: cert, uf: "SP")   # homologação by default
    #   client.status.online?
    #   signed = client.sign(invoice)          # store signed.xml before sending
    #   result = client.authorize(signed)
    #   File.write("#{result.key}-procNFe.xml", result.proc_xml) if result.authorized?
    #   result = client.resume(result.receipt, [result]) if result.pending?   # a lot accepted before 05/04/2027
    class Client
      # The mod of the notes it issues (DfeRb::Nfce::Client issues 65).
      MODEL = 55
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
      #
      # `endpoints:` also takes :qr_code and :consult_url, the state's addresses the QR code
      # of a note printed as the DANFE Simplificado Tipo 2 and its urlChave point to.
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

      # A new invoice for this client's environment. Fill it with a block and/or a hash. One
      # printed as the DANFE Simplificado Tipo 2 and issued off-line has its QR code signed
      # with this client's certificate.
      def build_invoice(attributes = nil, **fields, &block)
        Invoice.new(attributes, environment: environment, clock: @clock, technical_contact: @technical_contact,
          certificate: certificate, endpoints: @endpoints, **fields, &block)
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
        else Document.new(input)
        end
        check_model(document)
        document = validated(document, strict: strict) unless built_here?(input) || input.is_a?(SignedInvoice)
        check_environment(document)
        check_certificate(document)
        document = supplemented(document) unless document.signed?

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
      # The asynchronous lot is deprecated: SEFAZ rejects it from 01/02/2027 in homologação and
      # 05/04/2027 in production (RV GAP03a-6, rej. 129; NT 2023.002 v1.02), and from then on
      # a lot of several notes raises ValidationError before anything is sent. Send each note
      # in a call of its own: `notes.map { |note| client.authorize(note) }`.
      #
      # When the answer is lost (a timeout, say) or SEFAZ reports the key as a duplicate, it
      # looks the key up. If the stored note is this same document, it returns that note's
      # protocol (`result.recovered?` is true) instead of raising.
      #
      # If polling a lot times out or fails, the results come back pending and carry the
      # receipt. Finish them with #resume.
      #
      # Notes issued in SVC contingency (tpEmis 6 or 7) go to the state's SVC, and so do
      # #resume, #consult and #cancel for them. A note that names no IE for its issuer, a
      # contribuinte exclusivo do IBS/CBS (NT 2026.007), goes to the SVRS whatever the
      # client's state, which alone authorizes it (RV C17-11, rej. 166); so do its #resume
      # and the lookup of its key after a lost answer. Ask for its #consult, #cancel and
      # #correct with `via: :svrs`, since the key doesn't tell it.
      #
      # An NFC-e or a DANFE Simplificado Tipo 2 issued on-line reaches SEFAZ within 5 minutes
      # of its dhEmi (RV B09-40, rej. 704). With `recover`, one that late is looked up first:
      # SEFAZ may hold it from an earlier try, and then that result comes back; if it holds
      # nothing, ValidationError says so before anything is sent.
      def authorize(input, lot_id: nil, recover: true, polling: {}, strict: true)
        many = input.is_a?(Array)
        signed = Array(input).map { |item| sign(item, strict: strict) }
        raise ArgumentError, "nothing to authorize" if signed.empty?
        raise ArgumentError, "a lot holds at most #{MAX_LOT} notes (got #{signed.size})" if signed.size > MAX_LOT

        check_synchronous(signed)
        found = recover ? held_late_notes(signed) : {}
        unsent = signed.reject { |note| found.key?(note.key) }
        sent = unsent.empty? ? [] : transmit(unsent, lot_id: lot_id || new_lot_id, recover: recover, polling: DEFAULT_POLLING.merge(polling))
        answers = found.merge(unsent.map(&:key).zip(sent).to_h)
        results = signed.map { |note| answers[note.key] }
        many ? results : results.first
      end

      # Collects the answer to an asynchronous lot SEFAZ already accepted (cStat 103). Takes
      # the receipt and the notes sent in the lot, as SignedInvoices or as the pending
      # AuthorizationResults #authorize returned. Returns results as #authorize does.
      #
      # Deprecated with the asynchronous lot (see #authorize): SEFAZ issues no more receipts
      # once it rejects the lot, so this is only for a lot accepted before.
      def resume(receipt, notes, recover: true, polling: {})
        Deprecation.warn(:receipt_query, "Nfe::Client#resume and the receipt query (consReciNFe) go with the asynchronous " \
          "authorization lot, which SEFAZ rejects from #{Retirements.async_lot_ends(environment).strftime("%d/%m/%Y")} in " \
          "#{environment} (RV GAP03a-6, NT 2023.002 v1.02): use them only to finish a lot accepted before, and authorize " \
          "each note on its own")
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
      # there. `via: :home`, `via: :contingency` or `via: :svrs` (a note of an issuer without
      # IE) picks the authorizer yourself.
      def consult(key, via: nil)
        key = AccessKey.parse(key.to_s)
        response = Response.new(call(:consult, Requests.consult(key: key, environment: environment), uf: key.state,
          contingency: contingency?(key, via), svrs: via == :svrs))
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
        send_event(key, "110111", 1, detail, contingency: contingency?(key, via), svrs: via == :svrs)
      end

      # Corrects an authorized note (Carta de Correção, evento 110110). A new correction
      # replaces the previous one; `sequence` counts them (1..20). It goes to the state's own
      # authorizer, since the SVC takes no CC-e, unless you pass `via: :contingency`.
      def correct(key, text:, sequence: 1, via: :home)
        key = AccessKey.parse(key.to_s)
        raise ArgumentError, "sequence must be between 1 and 20" unless (1..20).cover?(sequence)

        detail = Requests.correction_detail(text: justification(text, "text", 15..1000))
        send_event(key, "110110", sequence, detail, contingency: contingency?(key, via), svrs: via == :svrs)
      end

      # Declares a range of numbers as unused (inutilização).
      #
      # AC, BA and SP have no inutilização service since 11/11/2026 (RV I01a, Ajustes SINIEF
      # 38/2026 and 40/2026; NT 2023.002 v1.02): for them it raises Unsupported before sending
      # anything, and it raises it too when SEFAZ answers 998 "Serviço Desativado" or HTTP 404.
      def inutilize(series:, from:, reason:, to: from, model: self.class::MODEL, year: @clock.now.year)
        raise ArgumentError, "from must not be greater than to" if from > to
        raise ArgumentError, "a request covers at most 10000 numbers" if to - from >= 10_000

        unsigned = Requests.inutilization(state: uf, year: year, tax_id: certificate.tax_id, model: model, series: series,
          from: from, to: to, reason: justification(reason, "reason", 15..255), environment: environment)
        raise Unsupported, Retirements.inutilization_message(uf) if Retirements.inutilization_off?(uf, @clock.now)

        signed = Signature.sign_inutilization(unsigned, certificate)

        response = begin
          Response.new(call(:inutilization, signed))
        rescue TransportError => e
          raise unless e.http_status == 404

          raise Unsupported, Retirements.inutilization_message(uf, answer: "HTTP 404")
        end
        raise Unsupported, Retirements.inutilization_message(uf, answer: "#{response.code} #{response.message}".strip) if response.code == StatusCodes::SERVICE_OFF

        InutilizationResult.new(code: response.code, message: response.message, protocol: response.text("nProt"),
          request_xml: signed, return_xml: response.fragment("retInutNFe"), xml: response.xml)
      end

      # Sends `xml` to a service as is and returns the answer's XML. Use it for anything the
      # client doesn't wrap. `service` is :status, :authorization, :authorization_return,
      # :consult, :inutilization or :event.
      def raw(service, xml, uf: self.uf, contingency: false)
        call(service, xml, uf: uf, contingency: contingency)
      end

      def endpoint(service, uf: self.uf, contingency: false, svrs: false)
        Endpoints.resolve(uf: uf, environment: environment, service: service, overrides: @endpoints, contingency: contingency,
          authorizer: ("SVRS" if svrs))
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

      def call(service, xml, uf: self.uf, contingency: false, svrs: false)
        transport.post(endpoint(service, uf: uf, contingency: contingency, svrs: svrs), xml)
      end

      # Whether a request about `key` goes to the SVC. It follows the key's tpEmis (6 or 7)
      # unless `via` names the authorizer.
      def contingency?(key, via)
        case via
        when nil then States::SVC_EMISSION_TYPES.value?(AccessKey.parse(key.to_s).emission_type)
        when :contingency then true
        when :home, :svrs then false
        else raise ArgumentError, "via must be :home, :contingency or :svrs (got #{via.inspect})"
        end
      end

      # A lot goes to one authorizer, so notes for the SVC can't share a lot with the others.
      def contingency_lot?(signed)
        kinds = signed.map { |note| contingency?(note.key, nil) }.uniq
        raise ArgumentError, "a lot can't mix notes issued for the SVC (tpEmis 6 or 7) with others" if kinds.size > 1

        kinds.first
      end

      # Whether a lot goes to the SVRS, the only authorizer of a note that names no IE for its
      # issuer (RV C17-11), unless it is one for the SVC, or the client's state is the SVRS's
      # already. It can't mix such notes with others.
      def svrs_lot?(signed)
        return false if States.authorizer(uf) == "SVRS"

        kinds = signed.map { |note| svrs_note?(note) }.uniq
        raise ArgumentError, "a lot can't mix notes of an issuer without IE (the SVRS's) with others" if kinds.size > 1

        kinds.first == true && !contingency_lot?(signed)
      end

      def svrs_note?(note) = Document.new(note.xml).without_state_registration?

      def new_lot_id = (@clock.now.to_f * 1000).to_i.to_s

      # A lot of several notes is an asynchronous request (indSinc 0), which SEFAZ rejects from
      # the day the NT sets (RV GAP03a-6, rej. 129): by the clock of the request or any note's
      # dhEmi. Before then it only warns that the lot is going away.
      def check_synchronous(signed)
        return if signed.size == 1

        issued = signed.map { |note| Document.new(note.xml).issued_at }
        raise ValidationError, [Retirements.async_lot_message(environment, signed.size)] if Retirements.async_lot_ended?(environment, [@clock.now, *issued])

        Deprecation.warn(:async_lot, "an asynchronous authorization lot (several notes in one #{self.class}#authorize call) " \
          "is rejected from #{Retirements.async_lot_ends(environment).strftime("%d/%m/%Y")} in #{environment} (RV GAP03a-6, rej. 129, " \
          "NT 2023.002 v1.02): authorize each note in its own call")
      end

      # Checks the schema, and the business rules unless `strict: false`, for XML that didn't
      # come from an Invoice. A note with a QR code (an NFC-e, or an NF-e printed as the DANFE
      # Simplificado Tipo 2) gets the NFC-e's rules too, and a signed one must carry its QR
      # code (RV ZX02-10), which no one may add after the signature, unless it is a note of
      # the Regime Especial NFF (tpEmis 3), which ZX02-10 exempts.
      def validated(document, strict:)
        problems = Schemas.nfe_issues(document.xml)
        problems += Validator.new(document.to_infnfe).issues if strict && problems.empty?
        raise ValidationError, problems unless problems.empty?
        return document unless document.qr_code?

        supplement = document.supplement
        if document.signed? && supplement.nil? && document.qr_code_required?
          raise ValidationError, ["infNFeSupl: a signed #{(document.model == "65") ? "NFC-e" : "NF-e with DANFE Simplificado Tipo 2"} " \
            "carries its QR code (rej. 394); it can't be added after signing"]
        end
        return document unless strict

        tree = document.to_infnfe
        problems = Nfce::Validator.new(tree, supplement: supplement, signer: document.signer || certificate.certificate,
          qr_address: qr_address(tree)).issues
        raise ValidationError, problems unless problems.empty?

        document
      end

      # The QR code address of the note's state and environment, or nil when they aren't known.
      def qr_address(tree)
        ide = tree["ide"] || {}
        Nfce::Endpoints.qr_code(uf: ide["cUF"], environment: ide["tpAmb"].to_s, overrides: @endpoints)
      rescue ArgumentError, KeyError
        nil
      end

      # A client issues one model: an NFC-e goes through DfeRb::Nfce::Client.
      def check_model(document)
        return if document.model.to_s == self.class::MODEL.to_s

        raise ValidationError, ["this is an NFC-e (modelo 65): issue it with DfeRb::Nfce::Client"] if document.model.to_s == "65"

        raise ValidationError, ["this is an NF-e modelo #{document.model} (ide/mod); #{self.class} issues modelo #{self.class::MODEL}"]
      end

      # An invoice of this client's model has passed its rules already; any other gets them here.
      def built_here?(input) = input.is_a?(Invoice) && input.class::MODEL == self.class::MODEL

      # An unsigned note with a QR code handed in without infNFeSupl gets it: the QR code and
      # urlChave of its state, signed with this client's certificate when issued off-line. One
      # that has it keeps it, but an off-line QR code must be signed by the certificate that
      # signs the note (NT 2026.003 §4.3.2, rej. 583). Any other note gets nothing.
      def supplemented(document)
        return document unless document.qr_code?

        if (supplement = document.supplement)
          check_qr_signer(supplement)
          return document
        end

        supplement, problems = Nfce::Supplement.build(document.to_infnfe, certificate: certificate, overrides: @endpoints)
        raise ValidationError, problems unless problems.empty?
        raise ValidationError, ["infNFe/@Id: the note has no access key to build its QR code from"] unless supplement

        supplied = document.with_supplement(supplement)
        problems = Schemas.nfe_issues(supplied.xml)
        raise ValidationError, problems unless problems.empty?

        supplied
      end

      def check_qr_signer(supplement)
        parsed = Nfce::QrCode.parse(supplement["qrCode"])
        return unless parsed&.dig(:signature)
        return if Nfce::QrCode.signed_by?(parsed[:signed_content], parsed[:signature], certificate.certificate)

        raise ValidationError, ["infNFeSupl/qrCode: its signature isn't this client's certificate's, which signs the note " \
          "(rej. 583); build the note with this client, or rebuild its QR code if it wasn't printed yet"]
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
        holder = certificate.cnpj ? "CNPJ root #{certificate.cnpj_root}" : ("CPF #{certificate.cpf}" if certificate.cpf)
        if issuer && holder && issuer[0, 8] != certificate.cnpj_root
          problems << "the certificate belongs to #{holder} but the issuer is #{issuer} (rej. 213)"
        elsif issuer_cpf && holder && issuer_cpf != certificate.cpf
          problems << "the certificate belongs to #{holder} but the issuer is #{issuer_cpf} (rej. 227)"
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
            contingency: contingency_lot?(signed), svrs: svrs_lot?(signed)))
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
          wait_for_lot(receipt, polling, contingency_lot?(signed), svrs_lot?(signed))
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
      def wait_for_lot(receipt, polling, contingency, svrs = false)
        @sleeper.call(polling[:wait])
        waited = polling[:wait]
        loop do
          answer = Response.new(call(:authorization_return, Requests.lot_return(receipt: receipt, environment: environment),
            contingency: contingency, svrs: svrs))
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

      # {key => result} of the notes past RV B09-40's 5 minutes that SEFAZ already holds. One
      # it doesn't hold is refused here; one the lookup can't settle is sent for SEFAZ to judge.
      def held_late_notes(signed)
        found = {}
        problems = []
        signed.each do |note|
          document = Document.new(note.xml)
          next unless document.qr_code?

          message = Nfce::Validator.late(document.to_infnfe, @clock.now) or next
          begin
            result = recovered(note, cause: StandardError.new(message))
          rescue TransportError
            next
          end
          result ? found[note.key] = result : problems << "#{message}. SEFAZ doesn't hold #{note.key}, so nothing was sent"
        end
        raise ValidationError, problems unless problems.empty?

        found
      end

      # Looks the key up after a lost answer or a duplicate report. Returns the result when SEFAZ
      # holds this very document, nil when it holds nothing (safe to send again), and raises
      # Conflict when it holds a different one. A note canceled since keeps its authorization
      # protocol but reports the consult's status (101...), so it is never taken as usable.
      def recovered(note, cause:)
        found = consult(note.key, via: (:svrs if svrs_note?(note) && !contingency?(note.key, nil)))
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
        response.fragments("procEventoNFe").map do |xml|
          fragment = Response.new(xml)
          EventSummary.new(
            type: fragment.text("tpEvento"), sequence: fragment.text("nSeqEvento")&.to_i,
            code: fragment.text("retEvento/infEvento/cStat")&.to_i, message: fragment.text("retEvento/infEvento/xMotivo"),
            protocol: fragment.text("retEvento/infEvento/nProt"), description: fragment.text("descEvento"), xml: xml
          )
        end
      end

      def send_event(key, type, sequence, detail, contingency: false, svrs: false)
        unsigned = Requests.event(key: key, type: type, sequence: sequence, detail: detail, environment: environment,
          at: States.now(key.state, @clock))
        signed = Signature.sign_event(unsigned, certificate)
        register_event(key, type, sequence, signed, endpoint(:event, uf: key.state, contingency: contingency, svrs: svrs))
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
