module DfeRb
  module Cte
    module Signature
      CTE = "http://www.portalfiscal.inf.br/cte"
      DS = DfeRb::Signature::DS
      NAMESPACES = {"cte" => CTE, "ds" => DS}.freeze

      module_function

      def sign_cte(xml, certificate) = DfeRb::Signature.sign(xml, certificate, namespace: CTE, container: "CTe", signed: "infCte")

      def sign_event(xml, certificate) = DfeRb::Signature.sign(xml, certificate, namespace: CTE, container: "eventoCTe", signed: "infEvento")

      def verify(xml, id: nil)
        document = Nokogiri::XML(xml) { |config| config.strict.nonet }
        root = document.root
        return "missing root element" unless root && root.namespace&.href == CTE

        target_name = case root.name
        when "CTe" then "infCte"
        when "eventoCTe" then "infEvento"
        else return "unexpected root <#{root.name}>"
        end

        signatures = root.xpath("ds:Signature", NAMESPACES)
        return "no signature" if signatures.empty?
        return "multiple signatures" if signatures.size > 1

        targets = root.xpath("cte:#{target_name}", NAMESPACES)
        return "no #{target_name} element" unless targets.size == 1

        target_id = targets.first["Id"]
        return "#{target_name} has no Id attribute" if target_id.to_s.empty?
        return "the signature references #{target_id}, not #{id}" if id && target_id != id

        reference_uri = signatures.first.at_xpath("ds:SignedInfo/ds:Reference/@URI", NAMESPACES)&.value
        return "the signature references #{reference_uri}, not ##{target_id}" unless reference_uri == "##{target_id}"

        DfeRb::Signature.verify(xml, id: target_id, of: target_id)
      rescue Nokogiri::XML::SyntaxError => e
        "not well-formed XML: #{e.message}"
      end

      def digest_value(xml) = DfeRb::Signature.digest_value(xml)
    end

    SignedWaybill = Data.define(:xml, :key, :digest_value, :qr_code) do
      def initialize(qr_code: nil, **fields) = super

      def to_s = xml
    end
  end
end
