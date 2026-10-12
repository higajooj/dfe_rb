module DfeRb
  module Nfe
    # An <NFe> handed in as XML (DfeRb::Document).
    class Document < DfeRb::Document
      ROOT = "NFe"
      INFO = "infNFe"
      NAMESPACE = Signature::NFE
      ID_PREFIX = "NFe"

      # infNFe as the tag-keyed Hash the Validator reads, following the schema.
      def to_infnfe = tree(Schema.nfe.find("infNFe"))
    end
  end
end
