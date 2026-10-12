module DfeRb
  module Mdfe
    # An <MDFe> handed in as XML (DfeRb::Document).
    class Document < DfeRb::Document
      ROOT = "MDFe"
      INFO = "infMDFe"
      NAMESPACE = Signature::MDFE
      ID_PREFIX = "MDFe"

      # infMDFe as the tag-keyed Hash the Validator reads, following the schema.
      def to_infmdfe = tree(Schema.mdfe.find("infMDFe"))

      # The URL in infMDFeSupl/qrCodMDFe, or nil.
      def qr_code = @root.at_xpath("doc:infMDFeSupl/doc:qrCodMDFe", namespaces)&.text&.strip

      # "1" (normal), "2" (contingency) or "3" (NFF), as declared in ide/tpEmis.
      def emission_type = text("ide/tpEmis")
    end
  end
end
