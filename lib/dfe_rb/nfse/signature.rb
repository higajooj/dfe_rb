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

      def verify(xml) = DfeRb::Signature.verify(xml)

      def digest_value(xml) = DfeRb::Signature.digest_value(xml)
    end

    # A signed DPS ready to send. Store `xml` before transmitting: the NFS-e the Sefin
    # generates carries these exact bytes, and `id` finds it again after a lost answer.
    SignedDeclaration = Data.define(:xml, :id, :digest_value) do
      def to_s = xml
    end
  end
end
