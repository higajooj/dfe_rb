module DfeRb
  module Nfse
    # DfeRb::Signature for the NFS-e documents the issuer signs: the DPS (infDPS) and the
    # request to register an event (infPedReg), in RSA-SHA256 with a SHA-256 digest.
    module Signature
      DS = DfeRb::Signature::DS
      NAMESPACES = {"nfse" => NAMESPACE, "ds" => DS}.freeze
      DIGEST = :sha256

      module_function

      # Signs the <DPS> in `xml`; returns the signed <DPS> element as a String (no XML
      # declaration, not reformatted, so its bytes are what the digest covers).
      def sign_dps(xml, certificate) = DfeRb::Signature.sign(xml, certificate, namespace: NAMESPACE, container: "DPS", signed: "infDPS", digest: DIGEST)

      def sign_event(xml, certificate) = DfeRb::Signature.sign(xml, certificate, namespace: NAMESPACE, container: "pedRegEvento", signed: "infPedReg", digest: DIGEST)

      # SHA-256, or SHA-1 for a DPS another application signed (the Sefin's API names no
      # algorithm); `id` is the Id the signature must reference.
      def verify(xml, id: nil) = DfeRb::Signature.verify(xml, digests: %i[sha256 sha1], id: id)

      def digest_value(xml) = DfeRb::Signature.digest_value(xml)

      # The digest a signed document's signature uses (:sha256 or :sha1).
      def digest_algorithm(xml)
        uri = Nokogiri::XML(xml).at_xpath("//ds:Signature/ds:SignedInfo/ds:Reference/ds:DigestMethod/@Algorithm", "ds" => DS)&.value
        DfeRb::Signature.algorithm(uri, 1) || DIGEST
      end
    end

    # A signed DPS ready to send. Store `xml` before transmitting: the NFS-e the Sefin
    # generates carries these exact bytes, and `id` finds it again after a lost answer.
    SignedDeclaration = Data.define(:xml, :id, :digest_value) do
      def to_s = xml
    end
  end
end
