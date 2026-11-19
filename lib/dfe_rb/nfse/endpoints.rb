require "erb"

module DfeRb
  module Nfse
    # Where each API of the Sistema Nacional NFS-e lives, as their OpenAPI documents give
    # them (sefin.nfse.gov.br/SefinNacional/swagger/docs/v1, adn.nfse.gov.br/contribuintes
    # and /parametrizacao). Homologação is "produção restrita". Each host can be overridden
    # per client with `endpoints: {sefin: "https://...", adn: "https://..."}`.
    module Endpoints
      BASES = {
        sefin: {
          Environment::PRODUCTION => "https://sefin.nfse.gov.br/SefinNacional",
          Environment::HOMOLOGACAO => "https://sefin.producaorestrita.nfse.gov.br/SefinNacional"
        },
        adn: {
          Environment::PRODUCTION => "https://adn.nfse.gov.br",
          Environment::HOMOLOGACAO => "https://adn.producaorestrita.nfse.gov.br"
        }
      }.freeze

      Service = Data.define(:host, :path)
      SERVICES = {
        issue: Service.new(host: :sefin, path: "/nfse"),
        consult: Service.new(host: :sefin, path: "/nfse/%{key}"),
        dps: Service.new(host: :sefin, path: "/dps/%{id}"),
        event: Service.new(host: :sefin, path: "/nfse/%{key}/eventos"),
        event_query: Service.new(host: :sefin, path: "/nfse/%{key}/eventos/%{type}/%{sequence}"),
        distribution: Service.new(host: :adn, path: "/contribuintes/DFe/%{nsu}"),
        events: Service.new(host: :adn, path: "/contribuintes/NFSe/%{key}/Eventos"),
        agreement: Service.new(host: :adn, path: "/parametrizacao/%{city}/convenio"),
        rates: Service.new(host: :adn, path: "/parametrizacao/%{city}/%{code}/%{date}/aliquota")
      }.freeze

      module_function

      # The URL of `service`, its path parameters filled in from `params` (escaped).
      #
      #   Endpoints.url(environment: :homologacao, service: :consult, key: "5002704...")
      def url(environment:, service:, overrides: {}, **params)
        definition = SERVICES.fetch(service) { raise ArgumentError, "unknown service: #{service.inspect} (#{SERVICES.keys.join(", ")})" }
        base = overrides[definition.host] || BASES.fetch(definition.host).fetch(Environment.normalize(environment))
        base.to_s.chomp("/") + format(definition.path, **params.transform_values { |value| ERB::Util.url_encode(value.to_s) })
      end
    end
  end
end
