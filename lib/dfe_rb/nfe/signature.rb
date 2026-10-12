module DfeRb
  module Nfe
    # DfeRb::Signature for the NF-e documents: the note (infNFe), an event (infEvento) and an
    # inutilização (infInut).
    module Signature
      NFE = "http://www.portalfiscal.inf.br/nfe"
      DS = DfeRb::Signature::DS
      C14N = DfeRb::Signature::C14N
      NAMESPACES = {"nfe" => NFE, "ds" => DS}.freeze

      module_function

      # Signs the <NFe> in `xml`; returns the signed <NFe> element as a String (no XML
      # declaration, not reformatted, so its bytes are what the digest covers).
      def sign_nfe(xml, certificate) = DfeRb::Signature.sign(xml, certificate, namespace: NFE, container: "NFe", signed: "infNFe")

      def sign_inutilization(xml, certificate) = DfeRb::Signature.sign(xml, certificate, namespace: NFE, container: "inutNFe", signed: "infInut")

      def sign_event(xml, certificate) = DfeRb::Signature.sign(xml, certificate, namespace: NFE, container: "evento", signed: "infEvento")

      def verify(xml) = DfeRb::Signature.verify(xml)

      def digest_value(xml) = DfeRb::Signature.digest_value(xml)

      def digest_of(node) = DfeRb::Signature.digest_of(node)
    end

    # A signed NF-e ready to send. Store `xml` before transmitting: its exact bytes are what
    # SEFAZ authorizes and what goes into the nfeProc.
    SignedInvoice = Data.define(:xml, :key, :digest_value) do
      def to_s = xml
    end

    # The signed EPEC event of the note `key`. Store `xml` before sending it.
    SignedEpec = Data.define(:xml, :key) do
      def to_s = xml
    end
  end
end
