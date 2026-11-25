require "base64"

module DfeRb
  module Cte
    class Document < DfeRb::Document
      ROOT = "CTe"
      INFO = "infCte"
      NAMESPACE = Signature::CTE
      ID_PREFIX = "CTe"

      def to_infcte = tree(Schema.cte.find("infCte"))

      def qr_code = @root.at_xpath("doc:infCTeSupl/doc:qrCodCTe", namespaces)&.text&.strip

      def signer
        encoded = @root.at_xpath("ds:Signature/ds:KeyInfo/ds:X509Data/ds:X509Certificate", namespaces)&.text
        OpenSSL::X509::Certificate.new(Base64.decode64(encoded)) if encoded
      rescue OpenSSL::X509::CertificateError
        nil
      end

      def emission_type = text("ide/tpEmis")

      def cte_type = text("ide/tpCTe")

      def model = text("ide/mod")&.to_i
    end
  end
end
