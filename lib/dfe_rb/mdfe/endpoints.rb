module DfeRb
  module Mdfe
    # Where each MDF-e web service lives. One authorizer, the SEFAZ Virtual RS, serves every
    # state (dfe-portal.svrs.rs.gov.br/Mdfe/Servicos). Every URL can be overridden per client
    # with `endpoints:`, so a moved URL doesn't block you.
    module Endpoints
      # request_tag: the element the payload goes in. answer: the root element of the answer,
      # which is found by name whatever the service wraps it in.
      Endpoint = Data.define(:service, :url, :namespace, :operation, :authorizer, :request_tag, :request_wrapper, :answer)

      # Web service (WSDL) name, SOAP operation and answer of each service.
      SERVICES = {
        status: {name: "MDFeStatusServico", operation: "mdfeStatusServicoMDF", answer: "retConsStatServMDFe"},
        authorization: {name: "MDFeRecepcaoSinc", operation: "mdfeRecepcao", answer: "retMDFe"},
        consult: {name: "MDFeConsulta", operation: "mdfeConsultaMDF", answer: "retConsSitMDFe"},
        unclosed: {name: "MDFeConsNaoEnc", operation: "mdfeConsNaoEnc", answer: "retConsMDFeNaoEnc"},
        event: {name: "MDFeRecepcaoEvento", operation: "mdfeRecepcaoEvento", answer: "retEventoMDFe"},
        distribution: {name: "MDFeDistribuicaoDFe", operation: "mdfeDistDFeInteresse", answer: "retDistDFeInt", wrapper: "mdfeDistDFeInteresse"}
      }.freeze
      SERVICE_KEYS = SERVICES.keys.freeze

      NAMESPACE = "http://www.portalfiscal.inf.br/mdfe/wsdl/%s"
      REQUEST_TAG = "mdfeDadosMsg"
      AUTHORIZER = "SVRS"
      BASES = {
        Environment::PRODUCTION => "https://mdfe.svrs.rs.gov.br/ws/",
        Environment::HOMOLOGACAO => "https://mdfe-homologacao.svrs.rs.gov.br/ws/"
      }.freeze

      module_function

      # The endpoint for a service.
      #
      #   Endpoints.resolve(environment: :homologacao, service: :authorization)
      #
      # `overrides` maps service names to URLs that replace the built-in ones.
      def resolve(environment:, service:, overrides: {})
        definition = SERVICES.fetch(service) { raise ArgumentError, "unknown service: #{service.inspect} (#{SERVICE_KEYS.join(", ")})" }
        name = definition[:name]
        url = overrides[service] || "#{BASES.fetch(Environment.normalize(environment))}#{name}/#{name}.asmx"

        Endpoint.new(service: service, url: url, namespace: format(NAMESPACE, name), operation: definition[:operation],
          authorizer: AUTHORIZER, request_tag: REQUEST_TAG, request_wrapper: definition[:wrapper], answer: definition[:answer])
      end
    end
  end
end
