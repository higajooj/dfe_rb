require "base64"

module DfeRb
  module Mdfe
    # The URL of infMDFeSupl/qrCodMDFe (MOC 9.2), which is also what the DAMDFE's QR code
    # holds. The Portal Nacional answers at one address for both environments and tells them
    # apart by tpAmb.
    module QrCode
      URL = "https://dfe-portal.svrs.rs.gov.br/mdfe/qrCode"

      module_function

      # The URL for `key`. With a certificate it carries `sign`, the key signed with RSA-SHA1,
      # which an MDF-e issued in contingency must have (MOC 9.2.2) and no other may.
      def url(key:, environment:, certificate: nil)
        base = "#{URL}?chMDFe=#{key}&tpAmb=#{Environment.code(environment)}"
        certificate ? "#{base}&sign=#{signature(key, certificate)}" : base
      end

      def signature(key, certificate)
        Base64.strict_encode64(certificate.private_key.sign(OpenSSL::Digest.new("SHA1"), key.to_s))
      end

      # Whether `sign` is `key` signed by the holder of `x509`, an OpenSSL certificate (F119).
      def signed_by?(key, sign, x509)
        x509.public_key.verify(OpenSSL::Digest.new("SHA1"), Base64.decode64(sign.to_s), key.to_s)
      rescue OpenSSL::PKey::PKeyError
        false
      end

      # {key:, environment:, sign:} read from a URL, or nil when it isn't one of these.
      def parse(url)
        address, query = url.to_s.split("?", 2)
        return unless address && query

        key = query[/(?:\A|&)chMDFe=([^&]*)/, 1]
        environment = query[/(?:\A|&)tpAmb=([^&]*)/, 1]
        return unless key && environment

        {address: address, key: key, environment: environment, sign: query[/(?:\A|&)sign=(.*)\z/m, 1]}
      end
    end
  end
end
