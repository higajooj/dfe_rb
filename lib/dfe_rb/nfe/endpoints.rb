module DfeRb
  module Nfe
    # Where each NF-e web service lives, per authorizer and environment.
    #
    # URLs come from the SEFAZ Virtual RS "Relação de Serviços Web" portal
    # (dfe-portal.svrs.rs.gov.br/Nfe/Servicos). Every URL can be overridden per client with
    # `endpoints:`, so a moved URL doesn't block you.
    module Endpoints
      # request_wrapper: an element some services want around <nfeDadosMsg>. answer: the root
      # element of the answer, for services whose SOAP body isn't the usual <nfeResultMsg>.
      Endpoint = Data.define(:service, :url, :namespace, :operation, :authorizer, :request_wrapper, :answer) do
        def initialize(request_wrapper: nil, answer: nil, **fields) = super
      end

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

      # The SEFAZ Virtuais de Contingência, which authorize a state's notes while its own
      # authorizer is down (States.contingency): [paths family, production base, homologação
      # base]. They take no inutilização (Anexo III 2.1.3.4 e).
      CONTINGENCY = {
        "SVC-AN" => [:an, "https://www.sefazvirtual.fazenda.gov.br/", "https://hom.sefazvirtual.fazenda.gov.br/"],
        "SVC-RS" => [:svrs, "https://nfe.svrs.rs.gov.br/ws/", "https://nfe-homologacao.svrs.rs.gov.br/ws/"]
      }.freeze
      CONTINGENCY_SERVICE_KEYS = (SERVICE_KEYS - [:inutilization]).freeze

      # Consulta cadastro (NfeConsultaCadastro, MOC 5.6) is offered by the consulted state, or
      # by the SVRS for the states in REGISTRY_SVRS. The others offer none. Each row is
      # [production, homologação].
      REGISTRY = {name: "CadConsultaCadastro4", operation: "consultaCadastro"}.freeze
      REGISTRY_URLS = {
        "AM" => ["https://nfe.sefaz.am.gov.br/services2/services/CadConsultaCadastro4", "https://homnfe.sefaz.am.gov.br/services2/services/CadConsultaCadastro4"],
        "BA" => ["https://nfe.sefaz.ba.gov.br/webservices/CadConsultaCadastro4/CadConsultaCadastro4.asmx", "https://hnfe.sefaz.ba.gov.br/webservices/CadConsultaCadastro4/CadConsultaCadastro4.asmx"],
        "GO" => ["https://nfe.sefaz.go.gov.br/nfe/services/CadConsultaCadastro4", "https://homolog.sefaz.go.gov.br/nfe/services/CadConsultaCadastro4"],
        "MG" => ["https://nfe.fazenda.mg.gov.br/nfe2/services/CadConsultaCadastro4", "https://hnfe.fazenda.mg.gov.br/nfe2/services/CadConsultaCadastro4"],
        "MS" => ["https://nfe.sefaz.ms.gov.br/ws/CadConsultaCadastro4", "https://hom.nfe.sefaz.ms.gov.br/ws/CadConsultaCadastro4"],
        "MT" => ["https://nfe.sefaz.mt.gov.br/nfews/v2/services/CadConsultaCadastro4", "https://homologacao.sefaz.mt.gov.br/nfews/v2/services/CadConsultaCadastro4"],
        "PE" => ["https://nfe.sefaz.pe.gov.br/nfe-service/services/CadConsultaCadastro4", "https://nfehomolog.sefaz.pe.gov.br/nfe-service/services/CadConsultaCadastro4"],
        "PR" => ["https://nfe.sefa.pr.gov.br/nfe/CadConsultaCadastro4", "https://homologacao.nfe.sefa.pr.gov.br/nfe/CadConsultaCadastro4"],
        "SP" => ["https://nfe.fazenda.sp.gov.br/ws/cadconsultacadastro4.asmx", "https://homologacao.nfe.fazenda.sp.gov.br/ws/cadconsultacadastro4.asmx"],
        "SVRS" => ["https://cad.svrs.rs.gov.br/ws/cadconsultacadastro/cadconsultacadastro4.asmx", "https://cad-homologacao.svrs.rs.gov.br/ws/cadconsultacadastro/cadconsultacadastro4.asmx"]
      }.freeze
      REGISTRY_SVRS = %w[AC ES PB RN RS SC].freeze
      # States that want <nfeDadosMsg> inside the operation's element.
      REGISTRY_WRAPPED = %w[MT].freeze
      REGISTRY_ANSWER = "retConsCad"

      module_function

      # The endpoint for a service of a state's authorizer, or of its SVC with `contingency`.
      #
      #   Endpoints.resolve(uf: "SP", environment: :homologacao, service: :authorization)
      #
      # `overrides` maps service names to URLs that replace the built-in ones; those of the
      # SVC go under :contingency ({contingency: {authorization: "https://..."}}).
      def resolve(uf:, environment:, service:, overrides: {}, contingency: false)
        definition = SERVICES.fetch(service) { raise ArgumentError, "unknown service: #{service.inspect} (#{SERVICE_KEYS.join(", ")})" }
        if contingency && !CONTINGENCY_SERVICE_KEYS.include?(service)
          raise ArgumentError, "the SVC has no #{service} service (use #{CONTINGENCY_SERVICE_KEYS.join(", ")})"
        end

        authorizer = contingency ? States.contingency(uf) : States.authorizer(uf)
        override = contingency ? overrides[:contingency]&.[](service) : overrides[service]
        url = override || url_for(authorizer, Environment.normalize(environment), service)

        Endpoint.new(service: service, url: url, namespace: format(NAMESPACE, definition[:name]),
          operation: definition[:operation], authorizer: authorizer)
      end

      def url_for(authorizer, environment, service)
        family, production_base, homologacao_base = AUTHORIZERS[authorizer] || CONTINGENCY.fetch(authorizer)
        base = (environment == Environment::PRODUCTION) ? production_base : homologacao_base
        base + PATHS.fetch(family).fetch(service)
      end

      # Whether `uf` can be asked about its taxpayers.
      def registry?(uf) = !registry_authorizer(uf).nil?

      # The consulta cadastro endpoint of the state consulted. Raises Unsupported for a
      # state that offers none (and has no override).
      def registry(uf:, environment:, overrides: {})
        state = States.abbreviation(uf)
        authorizer = registry_authorizer(state)
        url = overrides[:registry]
        url ||= REGISTRY_URLS.fetch(authorizer)[(Environment.normalize(environment) == Environment::PRODUCTION) ? 0 : 1] if authorizer
        raise Unsupported, "#{state} offers no consulta cadastro web service" unless url

        Endpoint.new(service: :registry, url: url, namespace: format(NAMESPACE, REGISTRY[:name]),
          operation: REGISTRY[:operation], authorizer: authorizer || state, answer: REGISTRY_ANSWER,
          request_wrapper: (REGISTRY[:operation] if REGISTRY_WRAPPED.include?(state)))
      end

      def registry_authorizer(uf)
        state = States.abbreviation(uf)
        if REGISTRY_URLS.key?(state)
          state
        elsif REGISTRY_SVRS.include?(state)
          "SVRS"
        end
      end
    end
  end
end
