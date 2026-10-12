module DfeRb
  module Nfe
    # Writes the <NFe> element (DfeRb::XmlWriter) from a tree of values.
    class XmlWriter < DfeRb::XmlWriter
      NAMESPACE = Signature::NFE

      def initialize(schema = Schema.nfe, namespace: NAMESPACE) = super
    end
  end
end
