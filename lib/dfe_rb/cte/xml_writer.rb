module DfeRb
  module Cte
    class XmlWriter < DfeRb::XmlWriter
      NAMESPACE = Signature::CTE

      def initialize(schema = Schema.cte, namespace: NAMESPACE) = super
    end
  end
end
