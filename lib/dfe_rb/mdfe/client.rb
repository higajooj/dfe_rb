module DfeRb
  module Mdfe
    # The entry point for emitting MDF-e with a certificate.
    #
    #   client = DfeRb::Mdfe::Client.new(certificate: cert, uf: "SP")   # homologação by default
    #   client.status.online?
    #   signed = client.sign(manifest)         # store signed.xml before sending
    #   result = client.authorize(signed)
    #   File.write(result.filename, result.proc_xml) if result.authorized?
    #   client.close(result.key, protocol: result.protocol, city: "3304557")   # when the trip ends
    class Client
      EVENTS = {cancellation: "110111", closing: "110112", driver: "110114", documents: "110115"}.freeze
      EXTERIOR_CITY = "9999999"
      EXTERIOR_STATE = "99"

      attr_reader :certificate, :uf, :environment, :transport

      # certificate: a DfeRb::Certificate.
      # uf:          the issuer's state.
      # environment: :homologacao (default, no fiscal value) or :production.
      # endpoints:   URL overrides per service, e.g. {authorization: "https://..."}.
      # transport:   anything with #post(endpoint, xml); defaults to the mTLS SOAP client.
      # technical_contact: the software house's infRespTec for every manifest built here
      #              ({cnpj:, contact:, email:, phone:, csrt_id:, csrt:}); see Manifest.
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

      # A new manifest for this client's environment. Fill it with a block and/or a hash.
      def build_manifest(attributes = nil, **fields, &block)
        Manifest.new(attributes, environment: environment, clock: @clock, certificate: certificate,
          technical_contact: @technical_contact, **fields, &block)
      end

      # Asks whether the authorizer is up (cStat 107). Wait three minutes between calls when
      # polling it (MOC 4.5.3).
      def status
        response = Response.new(call(:status, Requests.status(environment: environment)))
        StatusResult.new(code: response.code, message: response.message, state_code: response.text("cUF"),
          received_at: response.text("dhRecbto"), average_seconds: response.text("tMed")&.to_i,
          returns_at: response.text("dhRetorno"), note: response.text("xObs"), xml: response.xml)
      end

      # Validates and signs a Manifest, or raw <MDFe> XML (signed or not). Returns a
      # SignedManifest. Store its `xml` before sending, so a lost answer can be resolved later.
      #
      # Raw XML gets the same schema and business-rule checks as a Manifest. A SignedManifest
      # (or one restored from storage) isn't validated again, but like any input it must be
      # for this client's environment, belong to the certificate's owner and carry a
      # signature that verifies.
      #
      # `strict: false` skips the business-rule checks. The schema and value formats are
      # always enforced.
      def sign(input, strict: true)
        document = case input
        when Manifest then Document.new(input.to_xml(strict: strict))
        when SignedManifest then Document.new(input.xml)
        else validated(Document.new(input), strict: strict)
        end
        check_environment(document)
        check_certificate(document)

        signed = document.signed? ? document.xml : Signature.sign_mdfe(document.xml, certificate)
        problem = Signature.verify(signed)
        raise ValidationError, ["the signature does not verify: #{problem}"] unless problem == true

        result = SignedManifest.new(xml: signed, key: document.key, digest_value: Signature.digest_value(signed))
        (result == input) ? input : result
      end

      # Sends one MDF-e (the service takes one at a time and answers in the same call).
      # Accepts a Manifest, a SignedManifest or raw XML and returns an AuthorizationResult.
      #
      # When the answer is lost (a timeout, say) or SEFAZ reports the key as a duplicate, it
      # looks the key up. If the stored manifest is this same document, it returns that
      # manifest's protocol (`result.recovered?` is true) instead of raising.
      #
      # A manifest issued in contingency is sent the same way, once the problem is over and
      # within 168 hours of its emission.
      def authorize(input, recover: true, strict: true)
        manifest = sign(input, strict: strict)
        answer = begin
          Response.new(call(:authorization, Requests.authorization(manifest.xml)))
        rescue TransportError => e
          raise unless recover && e.maybe_processed?

          # If the lookup fails too, the first error stands. The manifest may have been
          # processed, whatever the lookup's own failure says.
          return recovered_quietly(manifest, e) || raise(e)
        end

        protocol_xml = answer.fragment("protMDFe")
        protocol = protocol_xml && Protocol.parse(protocol_xml)
        check_protocol(manifest, protocol) if protocol
        code = protocol&.code || answer.code
        if recover && StatusCodes.duplicate?(code)
          found = recovered(manifest, cause: protocol || answer)
          return found if found
        end
        build_result(manifest, code, protocol&.message || answer.message, protocol, answer.xml)
      end

      # Like #authorize, but raises Rejected, Unclosed or ConsumptionBlocked unless authorized.
      def authorize!(input, **options)
        result = authorize(input, **options)
        return result if result.authorized?

        raise ConsumptionBlocked, result if result.blocked?
        raise Unclosed, result if result.unclosed?
        raise Rejected, result
      end

      # Where a key stands at SEFAZ: authorized, canceled or closed, with its protocol and
      # events. Answers for 180 days after emission, and ten times an hour per key (MOC 8.2).
      def consult(key)
        key = AccessKey.parse(key.to_s)
        response = Response.new(call(:consult, Requests.consult(key: key, environment: environment)))
        protocol_xml = response.fragment("protMDFe")
        protocol = protocol_xml && Protocol.parse(protocol_xml)

        ConsultResult.new(
          key: key.to_s, code: response.code, message: response.message, protocol: protocol&.number,
          received_at: protocol&.received_at, digest_value: protocol&.digest_value, events: consult_events(response),
          protocol_xml: protocol_xml, xml: response.xml
        )
      end

      # The issuer's manifests still open, as keys and protocols: what #close needs. An open
      # manifest stops the next one for the same vehicle, and any after 30 days (F85 to F88).
      # `tax_id` defaults to the certificate's CNPJ or CPF.
      def unclosed(tax_id: certificate.tax_id)
        response = Response.new(call(:unclosed, Requests.unclosed(tax_id: tax_id, environment: environment)))
        manifests = response.nodes("infMDFe").map do |node|
          UnclosedManifest.new(key: node.at_xpath("chMDFe")&.text, protocol: node.at_xpath("nProt")&.text)
        end
        UnclosedResult.new(code: response.code, message: response.message, manifests: manifests, xml: response.xml)
      end

      # Cancels an authorized manifest (evento 110111). `protocol` is the authorization
      # protocol. Allowed for 24 hours after authorization, while the cargo hasn't moved.
      def cancel(key, protocol:, reason:)
        detail = Requests.cancellation(protocol: protocol_number(protocol), reason: justification(reason, "reason", 15..255))
        send_event(key, :cancellation, 1, detail)
      end

      # Closes a manifest when its trip ends (evento 110112). `city` is where it ended: an
      # IBGE code, or a name with `state:`; `:exterior` for a trip that ended abroad. `on` is
      # the day it ended.
      def close(key, protocol:, city:, state: nil, on: nil)
        key = AccessKey.parse(key.to_s)
        code, = (city.to_s == "exterior") ? [EXTERIOR_CITY] : Sugar.city([city, state].compact, {})
        detail = Requests.closing(protocol: protocol_number(protocol), on: on || States.now(key.state, @clock),
          state_code: (code == EXTERIOR_CITY) ? EXTERIOR_STATE : code[0, 2], city_code: code)
        send_event(key, :closing, 1, detail)
      end

      # Adds a driver to a road manifest (evento 110114). `sequence` counts the drivers added.
      def add_driver(key, name:, cpf:, sequence: 1)
        cpf = TaxId.normalize(cpf)
        raise ArgumentError, "cpf #{cpf} is not a valid CPF (rej. 645)" unless TaxId.valid_cpf?(cpf)

        send_event(key, :driver, sequence, Requests.driver(name: justification(name, "name", 2..60), cpf: cpf))
      end

      # Adds NF-e to a manifest issued to be loaded later, `later_loading` (evento 110115).
      # `load_at` is where they were loaded and `documents` what was loaded there, each a
      # Hash with the NF-e's key and where it unloads:
      #
      #   client.add_documents(key, protocol: "...", load_at: "3550308",
      #     documents: [{nfe: "3526...", unload_at: "3509502"}])
      #
      # A city is an IBGE code or a [name, state] pair. `sequence` counts the inclusions.
      def add_documents(key, protocol:, load_at:, documents:, sequence: 1)
        raise ArgumentError, "nothing to add" if Array(documents).empty?

        listed = Array(documents).map do |document|
          document = document.transform_keys(&:to_sym)
          nfe = DfeRb::AccessKey.parse(document.fetch(:nfe).to_s)
          raise ArgumentError, "#{nfe} is not an NF-e key (model 55, rej. 709)" unless nfe.model == 55

          [Sugar.city(Array(document.fetch(:unload_at)), {}), nfe.to_s]
        end
        detail = Requests.documents(protocol: protocol_number(protocol), loading: Sugar.city(Array(load_at), {}), documents: listed)
        send_event(key, :documents, sequence, detail)
      end

      # Sends `xml` to a service as is and returns the answer's XML. Use it for anything the
      # client doesn't wrap. `service` is :status, :authorization (whose payload is
      # Requests.authorization of a signed MDFe), :consult, :unclosed or :event.
      def raw(service, xml) = call(service, xml)

      def endpoint(service) = Endpoints.resolve(environment: environment, service: service, overrides: @endpoints)

      private

      def call(service, xml) = transport.post(endpoint(service), xml)

      # Checks the schema, and the business rules unless `strict: false`, for XML that didn't
      # come from a Manifest.
      def validated(document, strict:)
        problems = Schemas.mdfe_issues(document.xml)
        if strict && problems.empty?
          problems += Validator.new(document.to_infmdfe, qr_code: document.qr_code, clock: @clock,
            signer: document.signer || certificate.certificate).issues
        end
        raise ValidationError, problems unless problems.empty?

        document
      end

      def check_environment(document)
        declared = document.environment
        return if declared.nil? || declared == Environment.code(environment)

        raise ValidationError, ["the MDFe was built for #{(declared == "1") ? "production" : "homologacao"} " \
          "but this client talks to #{environment}"]
      end

      # The certificate must be valid and belong to the issuer (same CNPJ root, or same CPF).
      # One that names no one (not an ICP-Brasil one) is left for SEFAZ to judge.
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

      # The protocol must be about the manifest sent, and authorize the very bytes sent.
      def check_protocol(manifest, protocol)
        unless protocol.key == manifest.key
          raise Conflict, "SEFAZ answered about #{protocol.key}, not about #{manifest.key}, the manifest sent " \
            "(#{protocol.code} #{protocol.message}); consult the key to learn where it stands"
        end
        return unless StatusCodes.authorized?(protocol.code) && protocol.digest_value != manifest.digest_value

        raise Conflict, "SEFAZ authorized #{manifest.key} with digest #{protocol.digest_value}, " \
          "but the manifest sent has #{manifest.digest_value}"
      end

      def build_result(manifest, code, message, protocol, response_xml, recovered: false)
        AuthorizationResult.new(
          key: manifest.key, code: code, message: message, protocol: protocol&.number, received_at: protocol&.received_at,
          alerts: protocol&.alerts || [], digest_value: protocol&.digest_value, signed_xml: manifest.xml,
          protocol_xml: (protocol&.xml if protocol&.number), response_xml: response_xml, recovered: recovered
        )
      end

      # Like #recovered, but returns nil when the lookup fails too.
      def recovered_quietly(manifest, cause)
        recovered(manifest, cause: cause)
      rescue TransportError
        nil
      end

      # Looks the key up after a lost answer or a duplicate report. Returns the result when
      # SEFAZ holds this very document, nil when it holds nothing (safe to send again), and
      # raises Conflict when it holds a different one. A manifest canceled or closed since
      # keeps its authorization protocol but reports the consult's status (101, 132).
      def recovered(manifest, cause:)
        found = consult(manifest.key)
        return unless found.found? && found.protocol_xml

        unless found.digest_value == manifest.digest_value
          raise Conflict, "SEFAZ already holds #{manifest.key} with different content (#{found.code} #{found.message}); " \
            "the manifest being sent differs from the stored one. (#{cause.message})"
        end

        build_result(manifest, found.code, found.message, Protocol.parse(found.protocol_xml), found.xml, recovered: true)
      end

      def consult_events(response)
        response.fragments("procEventoMDFe").map do |xml|
          fragment = Response.new(xml)
          EventSummary.new(
            type: fragment.text("eventoMDFe/infEvento/tpEvento"), sequence: fragment.text("eventoMDFe/infEvento/nSeqEvento")&.to_i,
            code: fragment.text("retEventoMDFe/infEvento/cStat")&.to_i, message: fragment.text("retEventoMDFe/infEvento/xMotivo"),
            protocol: fragment.text("retEventoMDFe/infEvento/nProt"), description: fragment.text("descEvento"), xml: xml
          )
        end
      end

      def send_event(key, kind, sequence, detail)
        key = AccessKey.parse(key.to_s)
        raise ArgumentError, "#{key} is not an MDF-e key (model 58)" unless key.model == AccessKey::MODEL
        raise ArgumentError, "sequence must be between 1 and 99" unless (1..99).cover?(sequence)

        type = EVENTS.fetch(kind)
        unsigned = Requests.event(key: key, type: type, sequence: sequence, detail: detail, environment: environment,
          at: States.now(key.state, @clock))
        signed = Signature.sign_event(unsigned, certificate)
        problems = Schemas.event_issues(signed)
        raise ValidationError, problems unless problems.empty?

        response = Response.new(call(:event, signed))
        EventResult.new(
          key: key.to_s, type: type, sequence: sequence, code: response.code, message: response.message,
          protocol: response.text("infEvento/nProt"), registered_at: response.text("infEvento/dhRegEvento"),
          event_xml: signed, return_xml: response.fragment("retEventoMDFe"), xml: response.xml
        )
      end
    end
  end
end
