require "base64"
require "nokogiri"
require "openssl"

module DfeRb
  module Nfe
    # XML-DSig for NF-e documents: RSA-SHA1 over the SHA-1 digest of the C14N-1.0 form of the
    # element carrying the Id (infNFe, infEvento, infInut), with the enveloped-signature
    # transform and only the certificate in KeyInfo, as the layout schema fixes.
    module Signature
      NFE = "http://www.portalfiscal.inf.br/nfe"
      DS = "http://www.w3.org/2000/09/xmldsig#"
      NAMESPACES = {"nfe" => NFE, "ds" => DS}.freeze

      module_function

      # Signs the <NFe> in `xml`; returns the signed <NFe> element as a String (no XML
      # declaration, not reformatted, so its bytes are what the digest covers).
      def sign_nfe(xml, certificate) = sign(xml, certificate, container: "/nfe:NFe", signed: "infNFe")

      # <inutNFe> signed on infInut.
      def sign_inutilization(xml, certificate) = sign(xml, certificate, container: "/nfe:inutNFe", signed: "infInut")

      # A single <evento> signed on infEvento.
      def sign_event(xml, certificate) = sign(xml, certificate, container: "/nfe:evento", signed: "infEvento")

      def sign(xml, certificate, container:, signed:)
        signer = DfeRb::Signer.new(xml, noblanks: false, wss: false, canonicalize_algorithm: :c14n_1_0)
        signer.cert = certificate.certificate
        signer.private_key = certificate.private_key

        document = signer.document
        parent = document.at_xpath(container, NAMESPACES) or raise ArgumentError, "no #{container} element to sign"
        target = parent.at_xpath("nfe:#{signed}", NAMESPACES) or raise ArgumentError, "no #{signed} element to sign"
        id = target["Id"] or raise ArgumentError, "#{signed} has no Id attribute"
        raise ArgumentError, "#{container} is already signed" if parent.at_xpath("ds:Signature", NAMESPACES)

        signer.security_node = parent
        signer.digest!(target, id: id, enveloped: true, enveloped_first: true)
        signer.sign!(x509_certificate: true)

        parent.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
      end

      # Checks the signature inside `xml` (an <NFe>, <evento> or <inutNFe> element): digest of
      # the referenced element and the signature over SignedInfo with the embedded certificate.
      # Returns true, or the reason it fails.
      def verify(xml)
        document = Nokogiri::XML(xml)
        signature = document.at_xpath("//ds:Signature", NAMESPACES) or return "no signature"
        reference = signature.at_xpath("ds:SignedInfo/ds:Reference", NAMESPACES)
        id = reference["URI"].to_s.delete_prefix("#")
        target = document.at_xpath("//*[@Id='#{id}']") or return "referenced element #{id} not found"

        digest = Base64.strict_encode64(OpenSSL::Digest::SHA1.digest(target.canonicalize(Nokogiri::XML::XML_C14N_1_0)))
        expected = signature.at_xpath("ds:SignedInfo/ds:Reference/ds:DigestValue", NAMESPACES).text.strip
        return "digest mismatch" unless digest == expected

        certificate = OpenSSL::X509::Certificate.new(Base64.decode64(signature.at_xpath("ds:KeyInfo/ds:X509Data/ds:X509Certificate", NAMESPACES).text))
        signed_info = signature.at_xpath("ds:SignedInfo", NAMESPACES).canonicalize(Nokogiri::XML::XML_C14N_1_0)
        value = Base64.decode64(signature.at_xpath("ds:SignatureValue", NAMESPACES).text)
        certificate.public_key.verify(OpenSSL::Digest.new("SHA1"), value, signed_info) ? true : "signature value mismatch"
      end

      # The DigestValue of the signature in `xml`.
      def digest_value(xml)
        Nokogiri::XML(xml).at_xpath("//ds:Signature/ds:SignedInfo/ds:Reference/ds:DigestValue", NAMESPACES)&.text&.strip
      end
    end

    # A signed NF-e ready to send: keep `xml` (its exact bytes are what SEFAZ authorizes and
    # what goes into the nfeProc) and store it before transmitting.
    SignedInvoice = Data.define(:xml, :key, :digest_value) do
      def to_s = xml
    end

    # The signed EPEC event of the note `key`: store `xml` before sending it.
    SignedEpec = Data.define(:xml, :key) do
      def to_s = xml
    end
  end
end
