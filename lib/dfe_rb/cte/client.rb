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
        presumed_credit: "211110",
        disagreement: "610110",
        cancel_disagreement: "610111"
      }.freeze
      SVC_EMISSION_TYPES = %w[7 8].freeze
      SIGNED_QR_EMISSION_TYPES = Waybill::SIGNED_QR_EMISSION_TYPES
      NFF_EMISSION_TYPE = 3

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
        when Waybill
          Document.new(input.to_xml(strict: strict))
        when SignedWaybill
          doc = Document.new(input.xml)
          problems = Schemas.cte_issues(doc.xml)
          raise ValidationError, problems unless problems.empty?
          doc
        else
          validated(Document.new(input), strict: strict)
        end
        check_model(document)
        check_environment(document)
        check_certificate(document)
        check_qr_binding(document)

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

        answer, outer_code, outer_message, protocol = begin
          raw_answer = Response.new(call(:authorization, Requests.authorization(waybill.xml), uf: key.state, contingency: contingency))
          parse_authorization_response(raw_answer, waybill)
        rescue TransportError => e
          raise unless recover && e.maybe_processed?

          return recovered_quietly(waybill, e, contingency: contingency) || raise(e)
        end

        code = protocol&.code || outer_code
        message = protocol&.message || outer_message
        if recover && code == StatusCodes::DUPLICATE_DIFFERENT_KEY
          existing = existing_key_from_539(message, waybill_key: key)
          detail = existing ? " (#{existing})" : ""
          raise Conflict.new(
            "SEFAZ already authorized this CT-e number under a different access key#{detail}: #{message}",
            existing_key: existing
          )
        end
        if recover && StatusCodes.duplicate?(code)
          found = recovered(waybill, cause: protocol || answer, contingency: contingency)
          return found if found
        end
        build_result(waybill, code, message, protocol, answer.xml)
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
        root = response.strict_root("retConsSitCTe")
        check_response_environment(response, root)
        code = response.strict_integer(root, "cStat", required: true)
        message = response.strict_text(root, "xMotivo", required: true)

        protocol_node = response.strict_element(root, "protCTe")
        protocol_xml = protocol_node&.dup&.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
        protocol = protocol_xml && Protocol.parse(protocol_xml)
        check_protocol_environment(protocol, response.xml) if protocol

        ConsultResult.new(
          key: key.to_s, code: code, message: message, protocol: protocol&.number,
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

      def claim_presumed_credit(key, base:, code:, ibs: nil, cbs: nil, payment_declaration: false, author: certificate.tax_id)
        code_str = code.to_s.strip
        raise ArgumentError, "code must be 2 digits (NT 2026.004 §7, rej. 1061)" unless code_str.match?(/\A\d{2}\z/)

        base_amount = BigDecimal(base.to_s)
        ibs_group = presumed_credit_leg(ibs, base_amount, "IBS", 1066) if ibs
        cbs_group = presumed_credit_leg(cbs, base_amount, "CBS", 1069) if cbs
        declaration = case payment_declaration
        when true then Requests::PRESUMED_CREDIT_DECLARATION
        when false, nil then nil
        else payment_declaration.to_s
        end

        detail = Requests.presumed_credit(
          base: base_amount, code: code_str, ibs: ibs_group, cbs: cbs_group, payment_declaration: declaration
        )
        send_event(key, :presumed_credit, 1, detail, author: author, authorizer: "SVRS")
      end

      def raw(service, xml, uf: self.uf, contingency: false, authorizer: nil)
        call(service, xml, uf: uf, contingency: contingency, authorizer: authorizer)
      end

      def endpoint(service, uf: self.uf, contingency: false, authorizer: nil)
        Endpoints.resolve(
          uf: uf, environment: environment, service: service, overrides: @endpoints,
          contingency: contingency, authorizer: authorizer
        )
      end

      private

      def call(service, xml, uf: self.uf, contingency: false, authorizer: nil)
        transport.post(endpoint(service, uf: uf, contingency: contingency, authorizer: authorizer), xml)
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
        problems = certificate_validity_issues
        signer_x509 = document.signed? ? document.signer : certificate.certificate
        if document.signed? && signer_x509.nil?
          problems << "the XML signature carries no readable X509 certificate (D01, rej. 290)"
        elsif signer_x509
          problems.concat(signer_identity_issues(document, signer_x509))
        end
        raise ValidationError, problems unless problems.empty?
      end

      def certificate_validity_issues
        problems = []
        problems << "the certificate expired on #{certificate.expires_at.utc.iso8601}" if certificate.expired?(@clock.now)
        problems << "the certificate is not valid yet (starts #{certificate.not_before.utc.iso8601})" if certificate.not_before > @clock.now
        problems
      end

      def signer_identity_issues(document, signer_x509)
        return [] if document.nff?

        signer_id = DfeRb::Certificate.tax_id_of(signer_x509)
        signer_cnpj = (signer_id if signer_id&.length == 14)
        signer_cpf = (signer_id if signer_id&.length == 11)
        holder = signer_cnpj ? "CNPJ root #{signer_cnpj[0, 8]}" : ("CPF #{signer_cpf}" if signer_cpf)

        if document.paa?
          paa_cnpj = document.paa_cnpj.to_s
          problems = []
          problems << "infPAA/CNPJPAA: #{paa_cnpj} is not a valid CNPJ (E05, rej. 909)" unless TaxId.valid_cnpj?(paa_cnpj)
          if holder && signer_cnpj != paa_cnpj
            problems << "the signing certificate belongs to #{holder} but infPAA/CNPJPAA is #{paa_cnpj} (E06, rej. 910)"
          end
          return problems
        end

        issuer = document.issuer_cnpj
        issuer_cpf = document.issuer_cpf
        if issuer && holder && issuer[0, 8] != signer_cnpj&.slice(0, 8)
          ["the signing certificate belongs to #{holder} but the issuer is #{issuer} (E03, rej. 213)"]
        elsif issuer_cpf && holder && issuer_cpf != signer_cpf
          ["the signing certificate belongs to #{holder} but the issuer is #{issuer_cpf} (E03, rej. 202)"]
        else
          []
        end
      end

      def check_qr_binding(document)
        qr_code = document.qr_code
        return if qr_code.to_s.empty?

        parts = QrCode.parse(qr_code)
        problems = []
        if parts.nil?
          problems << "infCTeSupl/qrCodCTe: #{qr_code} has no chCTe and tpAmb (G214, rej. 852)"
        else
          if document.environment && parts[:environment] != document.environment
            problems << "infCTeSupl/qrCodCTe: tpAmb #{parts[:environment]} differs from ide/tpAmb #{document.environment} (G214, rej. 852)"
          end
          if SIGNED_QR_EMISSION_TYPES.include?(document.emission_type.to_s)
            effective_signer = document.signed? ? document.signer : certificate.certificate
            if parts[:sign].nil?
              problems << "infCTeSupl/qrCodCTe: a CT-e issued in offline or EPEC contingency signs its key in `sign` (G215, rej. 853)"
            elsif effective_signer && !QrCode.signed_by?(document.key, parts[:sign], effective_signer)
              problems << "infCTeSupl/qrCodCTe: `sign` is not the key signed with the waybill's certificate (G217, rej. 855)"
            end
          end
        end
        raise ValidationError, problems unless problems.empty?
      end

      def parse_authorization_response(answer, waybill)
        root = answer.strict_root("retCTe")
        check_response_environment(answer, root)
        outer_code = answer.strict_integer(root, "cStat", required: true)
        outer_message = answer.strict_text(root, "xMotivo", required: true)
        protocol_node = answer.strict_element(root, "protCTe")
        protocol_xml = protocol_node&.dup&.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
        protocol = protocol_xml && Protocol.parse(protocol_xml)

        if protocol
          check_protocol(waybill, protocol, response_xml: answer.xml)
        elsif StatusCodes.authorized?(outer_code)
          raise InvalidResponse.new("SEFAZ returned cStat #{outer_code} without protCTe", response_xml: answer.xml)
        end

        [answer, outer_code, outer_message, protocol]
      end

      def check_response_environment(response, root)
        declared = response.strict_text(root, "tpAmb")
        expected = Environment.code(environment)
        return if declared.nil? || declared == expected

        raise InvalidResponse.new("SEFAZ answered for tpAmb #{declared}, expected #{expected}", response_xml: response.xml)
      end

      def check_protocol_environment(protocol, response_xml)
        expected = Environment.code(environment)
        return if protocol.environment.nil? || protocol.environment == expected

        raise InvalidResponse.new("protCTe environment #{protocol.environment} differs from #{expected}", response_xml: response_xml)
      end

      def existing_key_from_539(message, waybill_key:)
        candidate = message.to_s[/chCTe\s*:\s*\[?\s*([0-9A-Z]{44})\b/i, 1]
        return unless candidate && AccessKey.valid?(candidate)

        parsed = AccessKey.parse(candidate)
        same_identity = parsed.state_code == waybill_key.state_code &&
          parsed.tax_id == waybill_key.tax_id &&
          parsed.model == waybill_key.model &&
          parsed.series == waybill_key.series &&
          parsed.number == waybill_key.number &&
          parsed.to_s != waybill_key.to_s
        parsed.to_s if same_identity
      end

      def presumed_credit_leg(group, base_amount, label, rej)
        data = group.transform_keys(&:to_sym)
        rate = BigDecimal(data.fetch(:rate).to_s)
        expected = (base_amount * rate / 100).round(2, half: :up)
        amount = (data.key?(:amount) && !data[:amount].nil?) ? BigDecimal(data[:amount].to_s) : expected
        if (amount - expected).abs > Validator::TOLERANCE
          raise ArgumentError, "#{label} presumed credit #{amount.to_s("F")} differs from base * rate (#{expected.to_s("F")}) (NT 2026.004 §7, rej. #{rej})"
        end

        {rate: rate, amount: amount}
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

      def check_protocol(waybill, protocol, response_xml: protocol.xml, require_authorization: false)
        check_protocol_environment(protocol, response_xml)
        unless protocol.key == waybill.key
          raise Conflict, "SEFAZ answered about #{protocol.key}, not about #{waybill.key}, the waybill sent " \
            "(#{protocol.code} #{protocol.message}); consult the key to learn where it stands"
        end
        return unless require_authorization || StatusCodes.authorized?(protocol.code)

        unless protocol.complete_authorization?
          raise InvalidResponse.new("SEFAZ returned an incomplete authorization protocol for #{waybill.key}", response_xml: response_xml)
        end
        return if protocol.digest_value == waybill.digest_value

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
        return unless found.found?
        raise InvalidResponse.new("SEFAZ consult returned #{found.code} without protCTe", response_xml: found.xml) unless found.protocol_xml

        protocol = Protocol.parse(found.protocol_xml)
        check_protocol(waybill, protocol, response_xml: found.xml, require_authorization: true)

        build_result(waybill, found.code, found.message, protocol, found.xml, recovered: true)
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

      def send_event(key, kind, sequence, detail, author: nil, contingency: false, authorizer: nil)
        key = key.is_a?(AccessKey) ? key : AccessKey.parse(key.to_s)
        raise ArgumentError, "#{key} is not a CT-e key (model 57, rej. 732)" unless key.model == AccessKey::MODEL
        raise ArgumentError, "sequence must be between 1 and 999 (rej. 636)" unless (1..999).cover?(sequence)

        actor = author ? TaxId.normalize(author) : key.issuer_id
        check_event_certificate(actor, nff: key.emission_type == NFF_EMISSION_TYPE)

        type = EVENTS.fetch(kind)
        unsigned = Requests.event(
          key: key, type: type, sequence: sequence, detail: detail, environment: environment,
          at: States.now(key.state, @clock), author: actor
        )
        signed = Signature.sign_event(unsigned, certificate)
        problems = Schemas.event_issues(signed)
        raise ValidationError, problems unless problems.empty?

        raw = call(:event, signed, uf: key.state, contingency: contingency, authorizer: authorizer)
        parse_event_response(raw, key: key.to_s, type: type, sequence: sequence, event_xml: signed)
      end

      def check_event_certificate(actor, nff:)
        problems = certificate_validity_issues
        if actor.length == 11
          problems << "event author CPF #{actor} is not valid (N05, rej. 905)" unless TaxId.valid_cpf?(actor)
        elsif actor.length == 14
          problems << "event author CNPJ #{actor} is not valid (N04, rej. 627)" unless TaxId.valid_cnpj?(actor)
        else
          problems << "event author #{actor.inspect} must be a valid CNPJ or CPF (N04, rej. 627)"
        end

        unless nff
          holder = certificate.cnpj ? "CNPJ root #{certificate.cnpj_root}" : ("CPF #{certificate.cpf}" if certificate.cpf)
          if actor.length == 14 && holder && actor[0, 8] != certificate.cnpj_root
            problems << "the certificate belongs to #{holder} but the event author is #{actor} (E03, rej. 213)"
          elsif actor.length == 11 && holder && actor != certificate.cpf
            problems << "the certificate belongs to #{holder} but the event author is #{actor} (E03, rej. 202)"
          end
        end
        raise ValidationError, problems unless problems.empty?
      end

      def parse_event_response(raw_xml, key:, type:, sequence:, event_xml:)
        response = Response.new(raw_xml)
        root = response.strict_root("retEventoCTe")
        info = response.strict_element(root, "infEvento", required: true)
        check_response_environment(response, info)

        code = response.strict_integer(info, "cStat", required: true)
        message = response.strict_text(info, "xMotivo", required: true)
        returned_key = response.strict_text(info, "chCTe")
        returned_type = response.strict_text(info, "tpEvento")
        returned_seq = response.strict_integer(info, "nSeqEvento")
        registered_at = response.strict_text(info, "dhRegEvento")
        protocol = response.strict_text(info, "nProt")

        raise InvalidResponse.new("retEventoCTe chCTe #{returned_key} differs from #{key}", response_xml: raw_xml) if returned_key && returned_key != key
        raise InvalidResponse.new("retEventoCTe tpEvento #{returned_type} differs from #{type}", response_xml: raw_xml) if returned_type && returned_type != type
        raise InvalidResponse.new("retEventoCTe nSeqEvento #{returned_seq} differs from #{sequence}", response_xml: raw_xml) if returned_seq && returned_seq != sequence

        if StatusCodes.event_registered?(code)
          missing = []
          missing << "chCTe" if returned_key.nil?
          missing << "tpEvento" if returned_type.nil?
          missing << "nSeqEvento" if returned_seq.nil?
          missing << "dhRegEvento" if registered_at.nil?
          missing << "nProt" unless protocol&.match?(/\A\d{15}\z/)
          unless missing.empty?
            raise InvalidResponse.new("registered event (#{code}) missing/invalid #{missing.join(", ")}", response_xml: raw_xml)
          end
        end

        return_xml = root.dup.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
        EventResult.new(
          key: key, type: type, sequence: sequence, code: code, message: message,
          protocol: protocol, registered_at: registered_at,
          event_xml: event_xml, return_xml: return_xml, xml: raw_xml
        )
      end
    end
  end
end
