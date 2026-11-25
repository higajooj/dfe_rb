require "base64"

module DfeRb
  module Cte
    module QrCode
      URLS = {
        "MG" => ["https://portalcte.fazenda.mg.gov.br/portalcte/sistema/qrcode.xhtml", "https://portalcte.fazenda.mg.gov.br/portalcte/sistema/qrcode.xhtml"],
        "MS" => ["http://www.dfe.ms.gov.br/cte/qrcode", "http://www.dfe.ms.gov.br/cte/qrcode"],
        "MT" => ["https://www.sefaz.mt.gov.br/cte/qrcode", "https://homologacao.sefaz.mt.gov.br/cte/qrcode"],
        "PR" => ["http://www.fazenda.pr.gov.br/cte/qrcode", "http://www.fazenda.pr.gov.br/cte/qrcode"],
        "SP" => ["https://nfe.fazenda.sp.gov.br/CTeConsulta/qrCode", "https://homologacao.nfe.fazenda.sp.gov.br/CTeConsulta/qrCode"],
        "SVSP" => ["https://nfe.fazenda.sp.gov.br/CTeConsulta/qrCode", "https://homologacao.nfe.fazenda.sp.gov.br/CTeConsulta/qrCode"],
        "SVRS" => ["https://dfe-portal.svrs.rs.gov.br/cte/qrCode", "https://dfe-portal.svrs.rs.gov.br/cte/qrCode"]
      }.freeze

      module_function

      def base_url_for(state:, environment:)
        authorizer = States.authorizer(state)
        URLS.fetch(authorizer)[(Environment.normalize(environment) == Environment::PRODUCTION) ? 0 : 1]
      end

      def url(key:, state:, environment:, certificate: nil, base_url: nil)
        address = base_url || base_url_for(state: state, environment: environment)
        base = "#{address}?chCTe=#{key}&tpAmb=#{Environment.code(environment)}"
        certificate ? "#{base}&sign=#{signature(key, certificate)}" : base
      end

      def signature(key, certificate)
        Base64.strict_encode64(certificate.private_key.sign(OpenSSL::Digest.new("SHA1"), key.to_s))
      end

      def signed_by?(key, sign, x509)
        x509.public_key.verify(OpenSSL::Digest.new("SHA1"), Base64.decode64(sign.to_s), key.to_s)
      rescue OpenSSL::PKey::PKeyError
        false
      end

      def parse(url)
        address, query = url.to_s.split("?", 2)
        return unless address && query

        key = query[/(?:\A|&)chCTe=([^&]*)/, 1]
        environment = query[/(?:\A|&)tpAmb=([^&]*)/, 1]
        return unless key && environment

        {address: address, key: key, environment: environment, sign: query[/(?:\A|&)sign=(.*)\z/m, 1]}
      end
    end
  end
end
