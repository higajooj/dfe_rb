require "base64"
require "nokogiri"
require "openssl"

module DfeRb
  # XML-DSig as the DF-e layouts fix it: RSA over the digest of the C14N-1.0 form of the
  # element carrying the Id (infNFe, infMDFe, infEvento, infDPS...), with the
  # enveloped-signature transform and only the certificate in KeyInfo. The SEFAZ documents
  # take SHA-1; the NFS-e takes SHA-256.
  module Signature
    DS = "http://www.w3.org/2000/09/xmldsig#"
    C14N = "http://www.w3.org/TR/2001/REC-xml-c14n-20010315"
    Algorithm = Data.define(:signature_method, :digest_method)
    ALGORITHMS = {
      sha1: Algorithm.new(signature_method: "#{DS}rsa-sha1", digest_method: "#{DS}sha1"),
      sha256: Algorithm.new(signature_method: "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256",
        digest_method: "http://www.w3.org/2001/04/xmlenc#sha256")
    }.freeze

    module_function

    # Signs the `signed` child of the root element `container` of `xml`, both in `namespace`;
    # returns the container with its <Signature> as a String (no XML declaration, not
    # reformatted, so its bytes are what the digest covers).
    #
    #   Signature.sign(xml, certificate, namespace: "http://www.portalfiscal.inf.br/mdfe", container: "MDFe", signed: "infMDFe")
    def sign(xml, certificate, namespace:, container:, signed:, digest: :sha1)
      algorithm = ALGORITHMS.fetch(digest)
      namespaces = {"doc" => namespace, "ds" => DS}
      document = Nokogiri::XML(xml.to_s)
      parent = document.at_xpath("/doc:#{container}", namespaces) or raise ArgumentError, "no <#{container}> element to sign"
      target = parent.at_xpath("doc:#{signed}", namespaces) or raise ArgumentError, "no #{signed} element to sign"
      id = target["Id"] or raise ArgumentError, "#{signed} has no Id attribute"
      raise ArgumentError, "<#{container}> is already signed" if parent.at_xpath("ds:Signature", namespaces)

      signature = parent.add_child(
        %(<Signature xmlns="#{DS}"><SignedInfo><CanonicalizationMethod Algorithm="#{C14N}"/>) +
        %(<SignatureMethod Algorithm="#{algorithm.signature_method}"/><Reference URI="##{id}"><Transforms>) +
        %(<Transform Algorithm="#{DS}enveloped-signature"/><Transform Algorithm="#{C14N}"/></Transforms>) +
        %(<DigestMethod Algorithm="#{algorithm.digest_method}"/><DigestValue>#{digest_of(target, digest)}</DigestValue></Reference></SignedInfo>) +
        %(<SignatureValue/><KeyInfo><X509Data><X509Certificate>#{certificate.base64}</X509Certificate></X509Data></KeyInfo></Signature>)
      ).first
      signed_info = signature.at_xpath("ds:SignedInfo", namespaces).canonicalize(Nokogiri::XML::XML_C14N_1_0)
      value = certificate.private_key.sign(OpenSSL::Digest.new(digest.to_s.upcase), signed_info)
      signature.at_xpath("ds:SignatureValue", namespaces).content = Base64.strict_encode64(value)

      parent.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
    end

    # Checks the signature inside `xml` (a signed document, event or request): digest of the
    # referenced element and the signature over SignedInfo with the embedded certificate.
    # `digests` are the ALGORITHMS the document's layout allows (SHA-1 for the SEFAZ
    # documents), and `id`, when given, the Id the signature must reference. A document
    # signed twice (an NFS-e: its DPS, then the Sefin) has the first checked, or the one
    # referencing `of`. Returns true, or the reason it fails.
    def verify(xml, digests: %i[sha1], id: nil, of: nil)
      namespaces = {"ds" => DS}
      document = Nokogiri::XML(xml)
      signature = if of
        document.xpath("//ds:Signature", namespaces).find { |node| node.at_xpath("ds:SignedInfo/ds:Reference/@URI", namespaces)&.value == "##{of}" } or
          return "no signature references #{of}"
      else
        document.at_xpath("//ds:Signature", namespaces) or return "no signature"
      end
      reference = signature.at_xpath("ds:SignedInfo/ds:Reference", namespaces)
      referenced = reference["URI"].to_s.delete_prefix("#")
      return "the signature references #{referenced}, not #{id}" if id && referenced != id

      target = document.at_xpath("//*[@Id='#{referenced}']") or return "referenced element #{referenced} not found"

      digest = by_digest_method(signature.at_xpath("ds:SignedInfo/ds:Reference/ds:DigestMethod/@Algorithm", namespaces)&.value)
      return "unknown digest method" unless digest
      return "#{digest.to_s.upcase} is not a digest this document takes (#{digests.join(", ")})" unless digests.include?(digest)
      return "the signature and digest methods differ" unless digest == by_signature_method(signature.at_xpath("ds:SignedInfo/ds:SignatureMethod/@Algorithm", namespaces)&.value)

      expected = signature.at_xpath("ds:SignedInfo/ds:Reference/ds:DigestValue", namespaces).text.strip
      return "digest mismatch" unless digest_of(target, digest) == expected

      certificate = OpenSSL::X509::Certificate.new(Base64.decode64(signature.at_xpath("ds:KeyInfo/ds:X509Data/ds:X509Certificate", namespaces).text))
      signed_info = signature.at_xpath("ds:SignedInfo", namespaces).canonicalize(Nokogiri::XML::XML_C14N_1_0)
      value = Base64.decode64(signature.at_xpath("ds:SignatureValue", namespaces).text)
      certificate.public_key.verify(OpenSSL::Digest.new(digest.to_s.upcase), value, signed_info) ? true : "signature value mismatch"
    end

    def digest_value(xml)
      Nokogiri::XML(xml).at_xpath("//ds:Signature/ds:SignedInfo/ds:Reference/ds:DigestValue", "ds" => DS)&.text&.strip
    end

    def digest_of(node, digest = :sha1)
      Base64.strict_encode64(OpenSSL::Digest.new(digest.to_s.upcase).digest(node.canonicalize(Nokogiri::XML::XML_C14N_1_0)))
    end

    def by_digest_method(uri) = ALGORITHMS.find { |_, algorithm| algorithm.digest_method == uri }&.first

    def by_signature_method(uri) = ALGORITHMS.find { |_, algorithm| algorithm.signature_method == uri }&.first
  end
end
