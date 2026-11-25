module DfeRb
  module Cte
    class Client
      EVENTS = {
        correction: "110110",
        cancellation: "110111",
        multimodal_record: "110160",
        delivery_receipt: "110180",
        cancel_delivery_receipt: "110181",
        delivery_failure: "110190",
        cancel_delivery_failure: "110191",
        payment_link: "110300",
        cancel_payment_link: "110301",
        disagreement: "610110",
        cancel_disagreement: "610111"
      }.freeze
      SVC_EMISSION_TYPES = %w[7 8].freeze

      attr_reader :certificate, :uf, :environment, :transport

      def initialize(certificate:, uf:, environment: Environment::HOMOLOGACAO, endpoints: {}, transport: nil,
        timeouts: {}, logger: nil, clock: Time, technical_contact: nil)
        @certificate = certificate
        @uf = States.abbreviation(uf)
        @environment = Environment.normalize(environment)
        @endpoints = endpoints
        @transport = transport || Transport.new(certificate: certificate, timeouts: timeouts, logger: logger)
        @clock = clock
        @technical_contact = technical_contact
      end

      def production? = environment == Environment::PRODUCTION

      def build_waybill(attributes = nil, **fields, &block)
        Waybill.new(
          attributes, environment: environment, clock: @clock, certificate: certificate,
          technical_contact: @technical_contact, qr_code_url: @endpoints[:qr_code], **fields, &block
        )
      end

      def status(uf: self.uf, contingency: false)
        response = Response.new(call(:status, Requests.status(state: uf, environment: environment), uf: uf, contingency: contingency))
        StatusResult.new(
          code: response.code, message: response.message, state_code: response.text("cUF"),
          received_at: response.text("dhRecbto"), average_seconds: response.text("tMed")&.to_i,
          returns_at: response.text("dhRetorno"), note: response.text("xObs"), xml: response.xml
        )
      end

      def sign(input, strict: true)
        document = case input
        when Waybill then Document.new(input.to_xml(strict: strict))
        when SignedWaybill then Document.new(input.xml)
        else validated(Document.new(input), strict: strict)
        end
        check_model(document)
        check_environment(document)
        check_certificate(document)

        signed = document.signed? ? document.xml : Signature.sign_cte(document.xml, certificate)
        problem = Signature.verify(signed, id: document.key && "CTe#{document.key}")
        raise ValidationError, ["the signature does not verify: #{problem}"] unless problem == true

        result = SignedWaybill.new(
          xml: signed, key: document.key, digest_value: Signature.digest_value(signed), qr_code: document.qr_code
        )
        (result == input) ? input : result
      end

      def authorize(input, recover: true, strict: true)
        waybill = sign(input, strict: strict)
        key = AccessKey.parse(waybill.key)
        contingency = svc?(key)
        check_svc_match(key) if contingency

        answer = begin
          Response.new(call(:authorization, Requests.authorization(waybill.xml), uf: key.state, contingency: contingency))
        rescue TransportError => e
          raise unless recover && e.maybe_processed?

          return recovered_quietly(waybill, e, contingency: contingency) || raise(e)
        end

        protocol_xml = answer.fragment("protCTe")
        protocol = protocol_xml && Protocol.parse(protocol_xml)
        check_protocol(waybill, protocol) if protocol
        code = protocol&.code || answer.code
        if recover && StatusCodes.duplicate?(code)
          found = recovered(waybill, cause: protocol || answer, contingency: contingency)
          return found if found
        end
        build_result(waybill, code, protocol&.message || answer.message, protocol, answer.xml)
      end

      def authorize!(input, **options)
        result = authorize(input, **options)
        return result if result.authorized?

        raise ConsumptionBlocked, result if result.blocked?
        raise Rejected, result
      end

      def consult(key, contingency: nil)
        key = AccessKey.parse(key.to_s)
        via_svc = contingency.nil? ? svc?(key) : contingency
        response = Response.new(call(:consult, Requests.consult(key: key, environment: environment), uf: key.state, contingency: via_svc))
        protocol_xml = response.fragment("protCTe")
        protocol = protocol_xml && Protocol.parse(protocol_xml)

        ConsultResult.new(
          key: key.to_s, code: response.code, message: response.message, protocol: protocol&.number,
          received_at: protocol&.received_at, digest_value: protocol&.digest_value,
          events: consult_events(response), protocol_xml: protocol_xml, xml: response.xml
        )
      end

      def cancel(key, protocol:, reason:, contingency: nil)
        parsed = AccessKey.parse(key.to_s)
        via_svc = contingency.nil? ? svc?(parsed) : contingency
        detail = Requests.cancellation(protocol: protocol_number(protocol), reason: justification(reason, "reason", 15..255))
        send_event(parsed, :cancellation, 1, detail, contingency: via_svc)
      end

      def correct(key, changes:, sequence: 1)
        raise ArgumentError, "at least one change is required" if Array(changes).empty?
        raise ArgumentError, "sequence must be between 1 and 20 (rej. 636)" unless (1..20).cover?(sequence)

        send_event(key, :correction, sequence, Requests.correction(changes: Array(changes)))
      end

      def disagree(key, reason:, sequence: 1, author: certificate.tax_id)
        raise ArgumentError, "sequence must be between 1 and 20 (rej. 636)" unless (1..20).cover?(sequence)

        detail = Requests.disagreement(reason: justification(reason, "reason", 15..255))
        send_event(key, :disagreement, sequence, detail, author: author)
      end

      def cancel_disagreement(key, protocol:, sequence: 1, author: certificate.tax_id)
        raise ArgumentError, "sequence must be between 1 and 20 (rej. 636)" unless (1..20).cover?(sequence)

        detail = Requests.cancel_disagreement(protocol: protocol_number(protocol))
        send_event(key, :cancel_disagreement, sequence, detail, author: author)
      end

      def deliver(key, protocol:, document:, name:, delivered_at: nil, image: nil, hash: nil, hashed_at: nil,
        latitude: nil, longitude: nil, nfe: [], sequence: 1)
        parsed = AccessKey.parse(key.to_s)
        now = States.now(parsed.state, @clock)
        delivered_at ||= now
        digest = hash || (image && Requests.delivery_hash(key: parsed, image: image))
        raise ArgumentError, "pass image: or hash: for the delivery receipt" if digest.nil?

        nfe_keys = Array(nfe).map { |k| validate_nfe_key(k) }
        detail = Requests.delivery_receipt(
          protocol: protocol_number(protocol), delivered_at: delivered_at,
          document: justification(document, "document", 2..20), name: justification(name, "name", 2..60),
          hash: digest, hashed_at: hashed_at || now, latitude: latitude, longitude: longitude, nfe_keys: nfe_keys
        )
        send_event(parsed, :delivery_receipt, sequence, detail)
      end

      def cancel_delivery(key, protocol:, event_protocol:, sequence: 1)
        detail = Requests.cancel_delivery_receipt(
          protocol: protocol_number(protocol), event_protocol: protocol_number(event_protocol)
        )
        send_event(key, :cancel_delivery_receipt, sequence, detail)
      end

      def report_delivery_failure(key, protocol:, reason:, justification: nil, attempted_at: nil, attempt: nil,
        image: nil, hash: nil, hashed_at: nil, latitude: nil, longitude: nil, nfe: [], sequence: 1)
        parsed = AccessKey.parse(key.to_s)
        now = States.now(parsed.state, @clock)
        reason_code = reason.is_a?(Symbol) ? Requests::DELIVERY_FAILURE_REASONS.fetch(reason) { raise ArgumentError, "unknown delivery failure reason #{reason.inspect}" } : reason.to_s
        if reason_code == "4"
          justification = justification(justification, "justification", 15..256)
        elsif justification
          raise ArgumentError, "justification is only for reason :other (4)"
        end

        digest = hash || (image && Requests.delivery_hash(key: parsed, image: image))
        nfe_keys = Array(nfe).map { |k| validate_nfe_key(k) }
        detail = Requests.delivery_failure(
          protocol: protocol_number(protocol), attempted_at: attempted_at || now,
          reason: reason_code, justification: justification, attempt: attempt,
          hash: digest, hashed_at: digest ? (hashed_at || now) : nil,
          latitude: latitude, longitude: longitude, nfe_keys: nfe_keys
        )
        send_event(parsed, :delivery_failure, sequence, detail)
      end

      def cancel_delivery_failure(key, protocol:, event_protocol:, sequence: 1)
        detail = Requests.cancel_delivery_failure(
          protocol: protocol_number(protocol), event_protocol: protocol_number(event_protocol)
        )
        send_event(key, :cancel_delivery_failure, sequence, detail)
      end

      def record_multimodal(key, text:, document: nil, sequence: 1)
        raise ArgumentError, "sequence must be between 1 and 20 (rej. 636)" unless (1..20).cover?(sequence)

        detail = Requests.multimodal_record(text: justification(text, "text", 15..1000), document: document)
        send_event(key, :multimodal_record, sequence, detail)
      end

      def link_payment(key, protocol:, method:, transaction_id:, receiver_cnpj:, psp_cnpj_base:, number: 1, sequence: 1)
        method_code = method.is_a?(Symbol) ? Names.enum_value("tpMeioPgto", method) : method.to_s.rjust(2, "0")
        raise ArgumentError, "invalid payment link method #{method.inspect} (rej. 1003)" if Nfe::Tables.payment_link_method(method_code).nil?

        receiver = TaxId.normalize(receiver_cnpj)
        raise ArgumentError, "receiver_cnpj #{receiver} is not a valid CNPJ (rej. 1001)" unless TaxId.valid_cnpj?(receiver)

        detail = Requests.payment_link(
          protocol: protocol_number(protocol), number: number, transaction_id: transaction_id,
          method: method_code, receiver_cnpj: receiver, psp_cnpj_base: psp_cnpj_base
        )
        send_event(key, :payment_link, sequence, detail)
      end

      def cancel_payment_link(key, protocol:, event_protocol:, sequence: 1)
        detail = Requests.cancel_payment_link(
          protocol: protocol_number(protocol), event_protocol: protocol_number(event_protocol)
        )
        send_event(key, :cancel_payment_link, sequence, detail)
      end

      def raw(service, xml, uf: self.uf, contingency: false) = call(service, xml, uf: uf, contingency: contingency)

      def endpoint(service, uf: self.uf, contingency: false)
        Endpoints.resolve(uf: uf, environment: environment, service: service, overrides: @endpoints, contingency: contingency)
      end

      private

      def call(service, xml, uf: self.uf, contingency: false)
        transport.post(endpoint(service, uf: uf, contingency: contingency), xml)
      end

      def svc?(key) = SVC_EMISSION_TYPES.include?(key.emission_type.to_s)

      def check_svc_match(key)
        expected = States.contingency_emission_type(key.state)
        return if key.emission_type == expected

        raise ValidationError, ["#{key.state} uses #{States.contingency(key.state)} (tpEmis #{expected}), not tpEmis #{key.emission_type} (G011, rej. 516)"]
      end

      def check_model(document)
        return if document.model.nil? || document.model == AccessKey::MODEL

        raise ValidationError, ["expected a CT-e (model 57), got model #{document.model} (G013, rej. 732)"]
      end

      def validated(document, strict:)
        problems = Schemas.cte_issues(document.xml)
        if strict && problems.empty?
          problems += Validator.new(
            document.to_infcte, qr_code: document.qr_code, clock: @clock,
            signer: document.signer || certificate.certificate, qr_code_base_url: @endpoints[:qr_code]
          ).issues
        end
        raise ValidationError, problems unless problems.empty?

        document
      end

      def check_environment(document)
        declared = document.environment
        return if declared.nil? || declared == Environment.code(environment)

        raise ValidationError, ["the CTe was built for #{(declared == "1") ? "production" : "homologacao"} " \
          "but this client talks to #{environment}"]
      end

      def check_certificate(document)
        problems = []
        problems << "the certificate expired on #{certificate.expires_at.utc.iso8601}" if certificate.expired?(@clock.now)
        problems << "the certificate is not valid yet (starts #{certificate.not_before.utc.iso8601})" if certificate.not_before > @clock.now

        issuer = document.issuer_cnpj
        issuer_cpf = document.issuer_cpf
        holder = certificate.cnpj ? "CNPJ root #{certificate.cnpj_root}" : ("CPF #{certificate.cpf}" if certificate.cpf)
        if issuer && holder && issuer[0, 8] != certificate.cnpj_root
          problems << "the certificate belongs to #{holder} but the issuer is #{issuer} (rej. 213)"
        elsif issuer_cpf && holder && issuer_cpf != certificate.cpf
          problems << "the certificate belongs to #{holder} but the issuer is #{issuer_cpf} (rej. 202)"
        end
        raise ValidationError, problems unless problems.empty?
      end

      def validate_nfe_key(value)
        nfe = DfeRb::AccessKey.parse(value.to_s)
        raise ArgumentError, "#{nfe} is not an NF-e key (model 55, rej. 860)" unless nfe.model == 55

        nfe.to_s
      end

      def justification(text, name, range)
        clean = Formatter.sanitize(text)
        raise ArgumentError, "#{name} must have #{range.min} to #{range.max} characters (got #{clean.length})" unless range.cover?(clean.length)

        clean
      end

      def protocol_number(protocol)
        number = protocol.to_s.strip
        raise ArgumentError, "protocol must have 15 digits" unless number.match?(/\A\d{15}\z/)

        number
      end

      def check_protocol(waybill, protocol)
        unless protocol.key == waybill.key
          raise Conflict, "SEFAZ answered about #{protocol.key}, not about #{waybill.key}, the waybill sent " \
            "(#{protocol.code} #{protocol.message}); consult the key to learn where it stands"
        end
        return unless StatusCodes.authorized?(protocol.code) && protocol.digest_value != waybill.digest_value

        raise Conflict, "SEFAZ authorized #{waybill.key} with digest #{protocol.digest_value}, " \
          "but the waybill sent has #{waybill.digest_value}"
      end

      def build_result(waybill, code, message, protocol, response_xml, recovered: false)
        AuthorizationResult.new(
          key: waybill.key, code: code, message: message, protocol: protocol&.number,
          received_at: protocol&.received_at, alerts: protocol&.alerts || [],
          digest_value: protocol&.digest_value, qr_code: waybill.qr_code,
          signed_xml: waybill.xml, protocol_xml: (protocol&.xml if protocol&.number),
          response_xml: response_xml, recovered: recovered
        )
      end

      def recovered_quietly(waybill, cause, contingency:)
        recovered(waybill, cause: cause, contingency: contingency)
      rescue TransportError
        nil
      end

      def recovered(waybill, cause:, contingency:)
        found = consult(waybill.key, contingency: contingency)
        return unless found.found? && found.protocol_xml

        unless found.digest_value == waybill.digest_value
          raise Conflict, "SEFAZ already holds #{waybill.key} with different content (#{found.code} #{found.message}); " \
            "the waybill being sent differs from the stored one. (#{cause.message})"
        end

        build_result(waybill, found.code, found.message, Protocol.parse(found.protocol_xml), found.xml, recovered: true)
      end

      def consult_events(response)
        response.fragments("procEventoCTe").map do |xml|
          fragment = Response.new(xml)
          EventSummary.new(
            type: fragment.text("eventoCTe/infEvento/tpEvento"),
            sequence: fragment.text("eventoCTe/infEvento/nSeqEvento")&.to_i,
            code: fragment.text("retEventoCTe/infEvento/cStat")&.to_i,
            message: fragment.text("retEventoCTe/infEvento/xMotivo"),
            protocol: fragment.text("retEventoCTe/infEvento/nProt"),
            description: fragment.text("descEvento"),
            xml: xml
          )
        end
      end

      def send_event(key, kind, sequence, detail, author: nil, contingency: false)
        key = key.is_a?(AccessKey) ? key : AccessKey.parse(key.to_s)
        raise ArgumentError, "#{key} is not a CT-e key (model 57, rej. 732)" unless key.model == AccessKey::MODEL
        raise ArgumentError, "sequence must be between 1 and 999 (rej. 636)" unless (1..999).cover?(sequence)

        type = EVENTS.fetch(kind)
        unsigned = Requests.event(
          key: key, type: type, sequence: sequence, detail: detail, environment: environment,
          at: States.now(key.state, @clock), author: author
        )
        signed = Signature.sign_event(unsigned, certificate)
        problems = Schemas.event_issues(signed)
        raise ValidationError, problems unless problems.empty?

        response = Response.new(call(:event, signed, uf: key.state, contingency: contingency))
        EventResult.new(
          key: key.to_s, type: type, sequence: sequence, code: response.code, message: response.message,
          protocol: response.text("infEvento/nProt"), registered_at: response.text("infEvento/dhRegEvento"),
          event_xml: signed, return_xml: response.fragment("retEventoCTe"), xml: response.xml
        )
      end
    end
  end
end
