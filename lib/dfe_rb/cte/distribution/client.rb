module DfeRb
  module Cte
    module Distribution
      class Client
        DEFAULT_MAX_DOCUMENT_BYTES = 10 * 1024 * 1024
        attr_reader :certificate, :uf, :tax_id, :environment, :transport

        def initialize(certificate:, uf:, tax_id: nil, environment: Environment::HOMOLOGACAO, endpoints: {},
          transport: nil, timeouts: {}, logger: nil, clock: Time, max_document_bytes: DEFAULT_MAX_DOCUMENT_BYTES)
          raise CertificateError, "certificate must be a DfeRb::Certificate" unless certificate.is_a?(Certificate)

          @certificate = certificate
          @uf = States.abbreviation(uf)
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

        def distribute(after: 0)
          query(:dist_nsu, "<distNSU><ultNSU>#{READER.nsu(after)}</ultNSU></distNSU>")
        end

        def fetch_nsu(nsu)
          normalized = READER.nsu(nsu, allow_zero: false)
          query(:cons_nsu, "<consNSU><NSU>#{normalized}</NSU></consNSU>", requested_nsu: normalized)
        end

        def distribute!(after: 0) = accepted!(distribute(after: after))

        def fetch_nsu!(nsu) = accepted!(fetch_nsu(nsu))

        def endpoint = Endpoints.resolve(environment: environment, overrides: @endpoints)

        def raw(xml)
          check_identity!
          transport.post(endpoint, xml)
        end

        private

        def query(kind, detail, requested_nsu: nil)
          check_identity!
          tag = (TaxId.type(tax_id) == :cnpj) ? "CNPJ" : "CPF"
          xml = %(<distDFeInt xmlns="#{Signature::CTE}" versao="#{VERSION}"><tpAmb>#{Environment.code(environment)}</tpAmb>) +
            "<cUFAutor>#{DfeRb::States.code(uf)}</cUFAutor><#{tag}>#{tax_id}</#{tag}>#{detail}</distDFeInt>"
          problems = Xsd.issues(xml, package: PACKAGE, file: "distDFeInt_v1.00.xsd")
          raise ValidationError, problems unless problems.empty?

          response = transport.post(endpoint, xml)
          DfeRb::Distribution::Response.new(
            response, reader: READER, documents: Documents, max_document_bytes: @max_document_bytes,
            require_nsu: true, require_cursors: true
          ).result(query: kind, request_xml: xml, environment: environment, received_at: @clock.now, requested_nsu: requested_nsu)
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
