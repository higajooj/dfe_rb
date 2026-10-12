module DfeRb
  module Mdfe
    module Distribution
      # One explicit request per call. The application owns scheduling, cursors, storage and
      # coordination between all consumers of the same interested party/environment.
      #
      #   client = DfeRb::Mdfe::Distribution::Client.new(certificate: cert)
      #   result = client.distribute(after: last_nsu)
      #   result.documents.each { |document| File.write(document.filename, document.xml) }
      #   last_nsu = result.last_nsu      # ask again while result.more?; else wait until result.retry_at
      #
      # What the interested party issued itself doesn't come (NT 2015.002 3.5).
      class Client
        DEFAULT_MAX_DOCUMENT_BYTES = 10 * 1024 * 1024
        attr_reader :certificate, :tax_id, :environment, :transport

        def initialize(certificate:, tax_id: nil, environment: Environment::HOMOLOGACAO, endpoints: {}, transport: nil,
          timeouts: {}, logger: nil, clock: Time, max_document_bytes: DEFAULT_MAX_DOCUMENT_BYTES)
          raise CertificateError, "certificate must be a DfeRb::Certificate" unless certificate.is_a?(Certificate)

          @certificate = certificate
          @tax_id = TaxId.normalize(tax_id.nil? ? certificate.tax_id : tax_id).freeze
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

        # Up to 50 documents after the NSU given, in NSU order. From zero (or an NSU too old)
        # it starts at the oldest one still kept.
        def distribute(after: 0)
          query(:dist_nsu, "<distNSU><ultNSU>#{READER.nsu(after)}</ultNSU></distNSU>")
        end

        # The document of one NSU, to fill a gap in what was received.
        def fetch_nsu(nsu)
          query(:cons_nsu, "<consNSU><NSU>#{READER.nsu(nsu, allow_zero: false)}</NSU></consNSU>")
        end

        def distribute!(after: 0) = accepted!(distribute(after: after))
        def fetch_nsu!(nsu) = accepted!(fetch_nsu(nsu))

        def endpoint = Endpoints.resolve(service: :distribution, environment: environment, overrides: @endpoints)

        # Sends `xml` to the service as is and returns the unparsed answer.
        def raw(xml)
          check_identity!
          transport.post(endpoint, xml)
        end

        private

        def query(kind, detail)
          check_identity!
          tag = (TaxId.type(tax_id) == :cnpj) ? "CNPJ" : "CPF"
          xml = %(<distDFeInt xmlns="#{Signature::MDFE}" versao="#{VERSION}"><tpAmb>#{Environment.code(environment)}</tpAmb>) +
            "<#{tag}>#{tax_id}</#{tag}>#{detail}</distDFeInt>"
          problems = Xsd.issues(xml, package: PACKAGE, file: "distDFeInt_v1.00.xsd")
          raise ValidationError, problems unless problems.empty?

          response = transport.post(endpoint, xml)
          DfeRb::Distribution::Response.new(response, reader: READER, documents: Documents, max_document_bytes: @max_document_bytes)
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

        def accepted!(result)
          raise ConsumptionBlocked, result if result.blocked?
          raise Rejected, result if result.rejected?
          result
        end
      end
    end
  end
end
