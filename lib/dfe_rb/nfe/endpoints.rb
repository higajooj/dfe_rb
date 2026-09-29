module DfeRb
  module Nfe
    # Where each NF-e web service lives, per authorizer and environment.
    #
    # URLs come from the SEFAZ Virtual RS "Relação de Serviços Web" portal
    # (dfe-portal.svrs.rs.gov.br/Nfe/Servicos). Every URL can be overridden per client with
    # `endpoints:`, so a moved URL never blocks anybody.
    module Endpoints
      Endpoint = Data.define(:service, :url, :namespace, :operation, :authorizer)

      # Web service (WSDL) name and SOAP operation of each service.
      SERVICES = {
        status: {name: "NFeStatusServico4", operation: "nfeStatusServicoNF"},
        authorization: {name: "NFeAutorizacao4", operation: "nfeAutorizacaoLote"},
        authorization_return: {name: "NFeRetAutorizacao4", operation: "nfeRetAutorizacaoLote"},
        consult: {name: "NFeConsultaProtocolo4", operation: "nfeConsultaNF"},
        inutilization: {name: "NFeInutilizacao4", operation: "nfeInutilizacaoNF"},
        event: {name: "NFeRecepcaoEvento4", operation: "nfeRecepcaoEventoNF"}
      }.freeze

      NAMESPACE = "http://www.portalfiscal.inf.br/nfe/wsdl/%s"

      SERVICE_KEYS = SERVICES.keys.freeze

      # Path of each service under an authorizer's base URL.
      PATHS = {
        # Axis-style deployments.
        java: {
          status: "NFeStatusServico4", authorization: "NFeAutorizacao4", authorization_return: "NFeRetAutorizacao4",
          consult: "NFeConsultaProtocolo4", inutilization: "NFeInutilizacao4", event: "NFeRecepcaoEvento4"
        },
        am_mt: {
          status: "NfeStatusServico4", authorization: "NfeAutorizacao4", authorization_return: "NfeRetAutorizacao4",
          consult: "NfeConsulta4", inutilization: "NfeInutilizacao4", event: "RecepcaoEvento4"
        },
        ba: {
          status: "NFeStatusServico4/NFeStatusServico4.asmx", authorization: "NFeAutorizacao4/NFeAutorizacao4.asmx",
          authorization_return: "NFeRetAutorizacao4/NFeRetAutorizacao4.asmx",
          consult: "NFeConsultaProtocolo4/NFeConsultaProtocolo4.asmx",
          inutilization: "NFeInutilizacao4/NFeInutilizacao4.asmx", event: "NFeRecepcaoEvento4/NFeRecepcaoEvento4.asmx"
        },
        svrs: {
          status: "NfeStatusServico/NfeStatusServico4.asmx", authorization: "NfeAutorizacao/NFeAutorizacao4.asmx",
          authorization_return: "NfeRetAutorizacao/NFeRetAutorizacao4.asmx", consult: "NfeConsulta/NfeConsulta4.asmx",
          inutilization: "nfeinutilizacao/nfeinutilizacao4.asmx", event: "recepcaoevento/recepcaoevento4.asmx"
        },
        sp: {
          status: "nfestatusservico4.asmx", authorization: "nfeautorizacao4.asmx",
          authorization_return: "nferetautorizacao4.asmx", consult: "nfeconsultaprotocolo4.asmx",
          inutilization: "nfeinutilizacao4.asmx", event: "nferecepcaoevento4.asmx"
        },
        an: {
          status: "NFeStatusServico4/NFeStatusServico4.asmx", authorization: "NFeAutorizacao4/NFeAutorizacao4.asmx",
          authorization_return: "NFeRetAutorizacao4/NFeRetAutorizacao4.asmx",
          consult: "NFeConsultaProtocolo4/NFeConsultaProtocolo4.asmx",
          inutilization: "NFeInutilizacao4/NFeInutilizacao4.asmx", event: "NFeRecepcaoEvento4/NFeRecepcaoEvento4.asmx"
        }
      }.freeze

      # authorizer => [paths family, production base, homologação base]
      AUTHORIZERS = {
        "AM" => [:am_mt, "https://nfe.sefaz.am.gov.br/services2/services/", "https://homnfe.sefaz.am.gov.br/services2/services/"],
        "BA" => [:ba, "https://nfe.sefaz.ba.gov.br/webservices/", "https://hnfe.sefaz.ba.gov.br/webservices/"],
        "GO" => [:java, "https://nfe.sefaz.go.gov.br/nfe/services/", "https://homolog.sefaz.go.gov.br/nfe/services/"],
        "MG" => [:java, "https://nfe.fazenda.mg.gov.br/nfe2/services/", "https://hnfe.fazenda.mg.gov.br/nfe2/services/"],
        "MS" => [:java, "https://nfe.sefaz.ms.gov.br/ws/", "https://hom.nfe.sefaz.ms.gov.br/ws/"],
        "MT" => [:am_mt, "https://nfe.sefaz.mt.gov.br/nfews/v2/services/", "https://homologacao.sefaz.mt.gov.br/nfews/v2/services/"],
        "PE" => [:java, "https://nfe.sefaz.pe.gov.br/nfe-service/services/", "https://nfehomolog.sefaz.pe.gov.br/nfe-service/services/"],
        "PR" => [:java, "https://nfe.sefa.pr.gov.br/nfe/", "https://homologacao.nfe.sefa.pr.gov.br/nfe/"],
        "RS" => [:svrs, "https://nfe.sefazrs.rs.gov.br/ws/", "https://nfe-homologacao.sefazrs.rs.gov.br/ws/"],
        "SP" => [:sp, "https://nfe.fazenda.sp.gov.br/ws/", "https://homologacao.nfe.fazenda.sp.gov.br/ws/"],
        "SVAN" => [:an, "https://www.sefazvirtual.fazenda.gov.br/", "https://hom.sefazvirtual.fazenda.gov.br/"],
        "SVRS" => [:svrs, "https://nfe.svrs.rs.gov.br/ws/", "https://nfe-homologacao.svrs.rs.gov.br/ws/"]
      }.freeze

      module_function

      # The endpoint for a service of a state's authorizer.
      #
      #   Endpoints.resolve(uf: "SP", environment: :homologacao, service: :authorization)
      #
      # `overrides` maps service names to URLs that replace the built-in ones.
      def resolve(uf:, environment:, service:, overrides: {})
        definition = SERVICES.fetch(service) { raise ArgumentError, "unknown service: #{service.inspect} (#{SERVICE_KEYS.join(", ")})" }
        authorizer = States.authorizer(uf)
        url = overrides[service] || url_for(authorizer, Environment.normalize(environment), service)

        Endpoint.new(service: service, url: url, namespace: format(NAMESPACE, definition[:name]),
          operation: definition[:operation], authorizer: authorizer)
      end

      def url_for(authorizer, environment, service)
        family, production_base, homologacao_base = AUTHORIZERS.fetch(authorizer)
        base = (environment == Environment::PRODUCTION) ? production_base : homologacao_base
        base + PATHS.fetch(family).fetch(service)
      end
    end
  end
end
