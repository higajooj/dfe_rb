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

      # Service => [host, path].
      SERVICES = {
        issue: [:sefin, "/nfse"],
        consult: [:sefin, "/nfse/%{key}"],
        dps: [:sefin, "/dps/%{id}"],
        event: [:sefin, "/nfse/%{key}/eventos"],
        event_query: [:sefin, "/nfse/%{key}/eventos/%{type}/%{sequence}"],
        distribution: [:adn, "/contribuintes/DFe/%{nsu}"],
        events: [:adn, "/contribuintes/NFSe/%{key}/Eventos"],
        agreement: [:adn, "/parametrizacao/%{city}/convenio"],
        rates: [:adn, "/parametrizacao/%{city}/%{code}/%{date}/aliquota"]
      }.freeze

      module_function

      # The URL of `service`, its path parameters filled in from `params` (escaped).
      #
      #   Endpoints.url(environment: :homologacao, service: :consult, key: "5002704...")
      def url(environment:, service:, overrides: {}, **params)
        host, path = SERVICES.fetch(service) { raise ArgumentError, "unknown service: #{service.inspect} (#{SERVICES.keys.join(", ")})" }
        base = overrides[host] || BASES.fetch(host).fetch(Environment.normalize(environment))
        base.to_s.chomp("/") + format(path, **params.transform_values { |value| ERB::Util.url_encode(value.to_s) })
      end
    end
  end
end
