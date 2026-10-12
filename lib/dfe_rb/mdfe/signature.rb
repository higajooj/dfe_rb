module DfeRb
  module Mdfe
    # DfeRb::Signature for the MDF-e documents: the manifest (infMDFe) and an event (infEvento).
    module Signature
      MDFE = "http://www.portalfiscal.inf.br/mdfe"
      DS = DfeRb::Signature::DS
      NAMESPACES = {"mdfe" => MDFE, "ds" => DS}.freeze

      module_function

      # Signs the <MDFe> in `xml`; returns the signed <MDFe> element as a String (no XML
      # declaration, not reformatted, so its bytes are what the digest covers).
      def sign_mdfe(xml, certificate) = DfeRb::Signature.sign(xml, certificate, namespace: MDFE, container: "MDFe", signed: "infMDFe")

      def sign_event(xml, certificate) = DfeRb::Signature.sign(xml, certificate, namespace: MDFE, container: "eventoMDFe", signed: "infEvento")

      def verify(xml) = DfeRb::Signature.verify(xml)

      def digest_value(xml) = DfeRb::Signature.digest_value(xml)
    end

    # A signed MDF-e ready to send. Store `xml` before transmitting: its exact bytes are what
    # SEFAZ authorizes and what goes into the mdfeProc.
    SignedManifest = Data.define(:xml, :key, :digest_value) do
      def to_s = xml
    end
  end
end
