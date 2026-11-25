module DfeRb
  module Cte
    module Distribution
      module Endpoints
        Endpoint = Data.define(:service, :url, :namespace, :operation, :authorizer, :request_wrapper, :request_tag, :result_tag, :answer)

        NAME = "CTeDistribuicaoDFe"
        OPERATION = "cteDistDFeInteresse"
        BASES = {
          Environment::PRODUCTION => "https://www1.cte.fazenda.gov.br/",
          Environment::HOMOLOGACAO => "https://hom1.cte.fazenda.gov.br/"
        }.freeze

        module_function

        def resolve(environment:, overrides: {})
          base = BASES.fetch(Environment.normalize(environment))
          url = overrides[:distribution] || "#{base}#{NAME}/#{NAME}.asmx"
          Endpoint.new(
            service: :distribution, url: url, namespace: format(Cte::Endpoints::NAMESPACE, NAME),
            operation: OPERATION, authorizer: "AN", request_wrapper: OPERATION,
            request_tag: Cte::Endpoints::REQUEST_TAG, result_tag: "#{OPERATION}Result",
            answer: "retDistDFeInt"
          )
        end
      end
    end
  end
end
