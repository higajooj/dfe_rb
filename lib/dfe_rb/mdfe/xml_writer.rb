module DfeRb
  module Mdfe
    # Writes the <MDFe> element (DfeRb::XmlWriter) from a tree of values.
    class XmlWriter < DfeRb::XmlWriter
      NAMESPACE = Signature::MDFE

      def initialize(schema = Schema.mdfe, namespace: NAMESPACE) = super
    end
  end
end
