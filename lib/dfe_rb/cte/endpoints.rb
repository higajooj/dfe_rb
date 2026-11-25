module DfeRb
  module Cte
    module Endpoints
      Endpoint = Data.define(:service, :url, :namespace, :operation, :authorizer, :request_tag, :answer)

      SERVICES = {
        status: {name: "CTeStatusServicoV4", operation: "cteStatusServicoCT", answer: "retConsStatServCTe"},
        authorization: {name: "CTeRecepcaoSincV4", operation: "cteRecepcao", answer: "retCTe"},
        consult: {name: "CTeConsultaV4", operation: "cteConsultaCT", answer: "retConsSitCTe"},
        event: {name: "CTeRecepcaoEventoV4", operation: "cteRecepcaoEvento", answer: "retEventoCTe"}
      }.freeze
      SERVICE_KEYS = SERVICES.keys.freeze

      NAMESPACE = "http://www.portalfiscal.inf.br/cte/wsdl/%s"
      REQUEST_TAG = "cteDadosMsg"

      AUTHORIZERS = {
        "MG" => [:plain, "https://cte.fazenda.mg.gov.br/cte/services/", "https://hcte.fazenda.mg.gov.br/cte/services/"],
        "MS" => [:plain, "https://producao.cte.ms.gov.br/ws/", "https://homologacao.cte.ms.gov.br/ws/"],
        "MT" => [:plain, "https://cte.sefaz.mt.gov.br/ctews2/services/", "https://homologacao.sefaz.mt.gov.br/ctews2/services/"],
        "PR" => [:plain, "https://cte.fazenda.pr.gov.br/cte4/", "https://homologacao.cte.fazenda.pr.gov.br/cte4/"],
        "SP" => [:sp, "https://nfe.fazenda.sp.gov.br/CTeWS/WS/", "https://homologacao.nfe.fazenda.sp.gov.br/CTeWS/WS/"],
        "SVSP" => [:sp, "https://nfe.fazenda.sp.gov.br/CTeWS/WS/", "https://homologacao.nfe.fazenda.sp.gov.br/CTeWS/WS/"],
        "SVRS" => [:svrs, "https://cte.svrs.rs.gov.br/ws/", "https://cte-homologacao.svrs.rs.gov.br/ws/"],
        "SVC-SP" => [:sp, "https://nfe.fazenda.sp.gov.br/CTeWS/WS/", "https://homologacao.nfe.fazenda.sp.gov.br/CTeWS/WS/"],
        "SVC-RS" => [:svrs, "https://cte.svrs.rs.gov.br/ws/", "https://cte-homologacao.svrs.rs.gov.br/ws/"]
      }.freeze

      module_function

      def resolve(uf:, environment:, service:, overrides: {}, contingency: false)
        definition = SERVICES.fetch(service) { raise ArgumentError, "unknown service: #{service.inspect} (#{SERVICE_KEYS.join(", ")})" }
        authorizer = contingency ? States.contingency(uf) : States.authorizer(uf)
        override = contingency ? overrides[:contingency]&.[](service) : overrides[service]
        url = override || url_for(authorizer, Environment.normalize(environment), definition[:name])

        Endpoint.new(
          service: service, url: url, namespace: format(NAMESPACE, definition[:name]),
          operation: definition[:operation], authorizer: authorizer, request_tag: REQUEST_TAG,
          answer: definition[:answer]
        )
      end

      def url_for(authorizer, environment, name)
        family, prod_base, hom_base = AUTHORIZERS.fetch(authorizer)
        base = (environment == Environment::PRODUCTION) ? prod_base : hom_base
        case family
        when :plain then "#{base}#{name}"
        when :sp then "#{base}#{name}.asmx"
        when :svrs then "#{base}#{name}/#{name}.asmx"
        end
      end
    end
  end
end
