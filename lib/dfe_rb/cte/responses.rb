module DfeRb
  module Cte
    class Response < DfeRb::Response
      NAMESPACE = Signature::CTE

      def strict_root(expected_root)
        doc = Nokogiri::XML(@xml) { |config| config.strict.nonet }
        raise InvalidResponse.new("response contains a DTD", response_xml: @xml) if doc.internal_subset || doc.external_subset

        root = doc.root
        unless root&.name == expected_root && root.namespace&.href == NAMESPACE
          raise InvalidResponse.new("expected <#{expected_root}> in the CT-e namespace", response_xml: @xml)
        end

        root
      rescue Nokogiri::XML::SyntaxError => e
        raise InvalidResponse.new("unreadable CT-e response: #{e.message}", response_xml: @xml)
      end

      def strict_element(node, path, required: false)
        matches = node.xpath(path.split("/").map { |tag| "doc:#{tag}" }.join("/"), namespaces)
        raise InvalidResponse.new("multiple #{path} elements", response_xml: @xml) if matches.size > 1
        raise InvalidResponse.new("missing #{path}", response_xml: @xml) if required && matches.empty?

        matches.first
      end

      def strict_text(node, path, required: false)
        value = strict_element(node, path, required: required)&.text&.strip
        raise InvalidResponse.new("missing #{path}", response_xml: @xml) if required && (value.nil? || value.empty?)

        value
      end

      def strict_integer(node, path, required: false)
        value = strict_text(node, path, required: required)
        return if value.nil?
        raise InvalidResponse.new("invalid #{path}: #{value.inspect}", response_xml: @xml) unless value.match?(/\A\d+\z/)

        value.to_i
      end
    end

    Protocol = Data.define(:key, :environment, :code, :message, :number, :received_at, :digest_value, :alerts, :xml) do
      def self.parse(element_xml)
        parsed = Response.new(element_xml)
        root = parsed.strict_root("protCTe")
        info = parsed.strict_element(root, "infProt", required: true)
        ns = {"doc" => Signature::CTE}
        new(
          key: parsed.strict_text(info, "chCTe"),
          environment: parsed.strict_text(info, "tpAmb"),
          code: parsed.strict_integer(info, "cStat", required: true),
          message: parsed.strict_text(info, "xMotivo"),
          number: parsed.strict_text(info, "nProt"),
          received_at: parsed.strict_text(info, "dhRecbto"),
          digest_value: parsed.strict_text(info, "digVal"),
          alerts: info.xpath("doc:infFisco", ns).map { |node| {code: node.at_xpath("doc:cMsg", ns)&.text, message: node.at_xpath("doc:xMsg", ns)&.text} },
          xml: element_xml
        )
      end

      def complete_authorization?
        StatusCodes.authorized?(code) &&
          !key.to_s.empty? &&
          number.to_s.match?(/\A\d{15}\z/) &&
          !received_at.to_s.empty? &&
          !digest_value.to_s.empty?
      end
    end

    module Proc
      DECLARATION = %(<?xml version="1.0" encoding="UTF-8"?>).freeze

      module_function

      def cte(signed_cte, protocol_xml, version: Schema::VERSION)
        %(#{DECLARATION}<cteProc xmlns="#{Signature::CTE}" versao="#{version}">#{signed_cte}#{protocol_xml}</cteProc>)
      end

      def event(signed_event, return_xml, version: Schema::VERSION)
        %(#{DECLARATION}<procEventoCTe xmlns="#{Signature::CTE}" versao="#{version}">#{signed_event}#{return_xml}</procEventoCTe>)
      end
    end
  end
end
