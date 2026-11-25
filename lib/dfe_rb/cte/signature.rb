module DfeRb
  module Cte
    module Signature
      CTE = "http://www.portalfiscal.inf.br/cte"
      DS = DfeRb::Signature::DS
      NAMESPACES = {"cte" => CTE, "ds" => DS}.freeze

      module_function

      def sign_cte(xml, certificate) = DfeRb::Signature.sign(xml, certificate, namespace: CTE, container: "CTe", signed: "infCte")

      def sign_event(xml, certificate) = DfeRb::Signature.sign(xml, certificate, namespace: CTE, container: "eventoCTe", signed: "infEvento")

      def verify(xml, id: nil) = DfeRb::Signature.verify(xml, id: id)

      def digest_value(xml) = DfeRb::Signature.digest_value(xml)
    end

    SignedWaybill = Data.define(:xml, :key, :digest_value, :qr_code) do
      def initialize(qr_code: nil, **fields) = super

      def to_s = xml
    end
  end
end
