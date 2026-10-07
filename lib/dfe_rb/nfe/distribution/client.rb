module DfeRb
  module Nfe
    module Distribution
      # One explicit request per call. The application owns scheduling, cursors, storage and
      # coordination between all consumers of the same interested party/environment.
      class Client
        MAX_EVENTS = 20
        DEFAULT_MAX_DOCUMENT_BYTES = 10 * 1024 * 1024
        attr_reader :certificate, :tax_id, :uf, :environment, :transport

        def initialize(certificate:, tax_id: nil, uf: nil, environment: Environment::HOMOLOGACAO,
          endpoints: {}, transport: nil, timeouts: {}, logger: nil, clock: Time,
          max_document_bytes: DEFAULT_MAX_DOCUMENT_BYTES)
          unless certificate.is_a?(Certificate)
            raise CertificateError, "certificate must be a DfeRb::Certificate"
          end
          @certificate = certificate
          @tax_id = TaxId.normalize(tax_id.nil? ? certificate.tax_id : tax_id).freeze
          @uf = uf && States.abbreviation(uf)
          @environment = Environment.normalize(environment)
          @endpoints = endpoints.dup.freeze
          @transport = transport || Transport.new(certificate: certificate, timeouts: timeouts, logger: logger)
          @clock = clock
          unless max_document_bytes.is_a?(Integer) && max_document_bytes.positive?
            raise ArgumentError, "max_document_bytes must be a positive integer"
          end
          @max_document_bytes = max_document_bytes
          check_identity!
        end

        def production? = environment == Environment::PRODUCTION

        def distribute(after: 0)
          query(:dist_nsu, "<distNSU><ultNSU>#{Xml.nsu(after)}</ultNSU></distNSU>")
        end

        def fetch_nsu(nsu)
          query(:cons_nsu, "<consNSU><NSU>#{Xml.nsu(nsu, allow_zero: false)}</NSU></consNSU>")
        end

        def fetch_key(key)
          query(:cons_key, "<consChNFe><chNFe>#{Xml.key(key)}</chNFe></consChNFe>")
        end

        def distribute!(after: 0) = accepted!(distribute(after: after))
        def fetch_nsu!(nsu) = accepted!(fetch_nsu(nsu))
        def fetch_key!(key) = accepted!(fetch_key(key))

        def prepare_manifestation(key, type:, sequence: 1, reason: nil, at: nil)
          check_identity!
          unsigned = Manifestations.build(key: Xml.key(key), type: type, sequence: sequence, reason: reason,
            tax_id: tax_id, environment: environment, at: at.nil? ? @clock.now.getutc : at)
          # Check the detail before signing so invalid justification characters fail locally.
          detail = Xml.parse(unsigned).at_xpath("/nfe:evento/nfe:infEvento/nfe:detEvento", Xml::NS)
          code, = Manifestations.definition(type)
          Schemas.validate!(Xml.fragment(detail), package: "Evento_ManifestaDest_PL_v1.01", file: "e#{code}_v1.00.xsd")
          SignedManifestation.new(xml: Signature.sign_event(unsigned, certificate)).verify!
        rescue Nokogiri::XML::SyntaxError, EncodingError => e
          raise ValidationError, ["invalid manifestation XML: #{e.message}"]
        end

        # Takes access keys or prepared events. A key is built with the given type and details.
        # A prepared event keeps its exact signed XML. An array may mix types, but only through
        # prepared events, and an array input always returns an array.
        def manifest(input, type: nil, sequence: nil, reason: nil, at: nil, lot_id: nil)
          check_identity!
          many = input.is_a?(Array)
          inputs = many ? input : [input]
          raise ArgumentError, "a manifestation lot holds 1..#{MAX_EVENTS} events" unless (1..MAX_EVENTS).cover?(inputs.size)
          events = inputs.map do |item|
            if item.is_a?(SignedManifestation)
              if [type, sequence, reason, at].any? { |option| !option.nil? }
                raise ArgumentError, "type/details cannot override a prepared manifestation"
              end
              check_event!(item)
            else
              raise ArgumentError, "type is required when manifesting an access key" unless type
              prepare_manifestation(item, type: type, sequence: sequence.nil? ? 1 : sequence, reason: reason, at: at)
            end
          end
          raise ArgumentError, "duplicate manifestation identities in lot" unless events.map(&:identity).uniq.size == events.size
          lot_id = normalize_lot_id(lot_id || (@clock.now.to_f * 1000).to_i.to_s)
          xml = Requests.event_batch(events.map(&:xml), lot_id: lot_id)
          Schemas.validate!(xml, package: "event_1.00", file: "envEvento_v1.00.xsd")
          response = transport.post(endpoint(:manifestation), xml)
          results = ManifestationResponse.new(response).results(events: events, request_xml: xml, environment: environment)
          many ? results.freeze : results.first
        end

        def manifest!(input, **options)
          result = manifest(input, **options)
          Array(result).each { |event| accepted!(event) }
          result
        end

        def endpoint(service) = Endpoints.resolve(service: service, environment: environment, overrides: @endpoints)

        # Sends `xml` to a national service as is and returns the unparsed answer.
        def raw(service, xml)
          check_identity!
          transport.post(endpoint(service), xml)
        end

        private

        def query(kind, detail)
          check_identity!
          tag = (TaxId.type(tax_id) == :cnpj) ? "CNPJ" : "CPF"
          state = uf ? "<cUFAutor>#{States.code(uf)}</cUFAutor>" : ""
          xml = %(<distDFeInt xmlns="#{Signature::NFE}" versao="1.01"><tpAmb>#{Environment.code(environment)}</tpAmb>) +
            "#{state}<#{tag}>#{tax_id}</#{tag}>#{detail}</distDFeInt>"
          Schemas.validate!(xml, package: "PL_NFeDistDFe_104", file: "distDFeInt_v1.01.xsd")
          response = transport.post(endpoint(:distribution), xml)
          DistributionResponse.new(response, max_document_bytes: @max_document_bytes)
            .result(query: kind, request_xml: xml, environment: environment, received_at: @clock.now)
        end

        def check_identity!
          raise CertificateError, "certificate is not valid at #{@clock.now.iso8601}" unless certificate.valid?(@clock.now)
          type = TaxId.type(tax_id)
          raise ValidationError, ["tax_id must be a valid CNPJ or CPF"] unless type
          matches = if type == :cnpj
            certificate.cnpj_root == tax_id[0, 8]
          else
            certificate.cnpj.nil? && certificate.cpf == tax_id
          end
          raise CertificateError, "interested party does not match the certificate's CNPJ base or CPF" unless matches
        end

        def check_event!(event)
          # Re-reads the stored bytes instead of trusting caller metadata or an earlier verification.
          checked = SignedManifestation.new(xml: event.xml)
          unless checked.tax_id == tax_id && checked.environment == environment
            raise ValidationError, ["manifestation author/environment differs from this client"]
          end
          checked.verify!
        end

        def normalize_lot_id(value)
          supported_type = value.is_a?(Integer) || value.is_a?(String)
          unless supported_type && value.to_s.match?(/\A\d{1,15}\z/)
            raise ArgumentError, "lot_id must have 1..15 digits"
          end
          value.to_s
        end

        def accepted!(result)
          raise ConsumptionBlocked, result if result.blocked?
          raise Rejected, result if result.rejected?
          result
        end
      end
    end
  end
end
