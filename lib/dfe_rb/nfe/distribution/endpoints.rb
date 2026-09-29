module DfeRb
  module Nfe
    module Distribution
      module Endpoints
        Endpoint = Data.define(:service, :url, :namespace, :operation, :authorizer, :request_wrapper, :result_tag)
        SERVICES = {
          distribution: ["NFeDistribuicaoDFe", "nfeDistDFeInteresse", "nfeDistDFeInteresse", "nfeDistDFeInteresseResult"],
          manifestation: ["NFeRecepcaoEvento4", "nfeRecepcaoEventoNF", nil, "nfeResultMsg"]
        }.freeze
        BASES = {
          distribution: {production: "https://www1.nfe.fazenda.gov.br/", homologacao: "https://hom.nfe.fazenda.gov.br/"},
          manifestation: {production: "https://www.nfe.fazenda.gov.br/", homologacao: "https://hom.nfe.fazenda.gov.br/"}
        }.freeze

        module_function

        def resolve(service:, environment:, overrides: {})
          name, operation, wrapper, result = SERVICES.fetch(service) { raise ArgumentError, "unknown service: #{service.inspect}" }
          base = BASES.fetch(service).fetch(Environment.normalize(environment))
          url = overrides[service] || "#{base}#{name}/#{name}.asmx"
          Endpoint.new(service: service, url: url, namespace: format(Nfe::Endpoints::NAMESPACE, name),
            operation: operation, authorizer: "AN", request_wrapper: wrapper, result_tag: result)
        end
      end
    end
  end
end
