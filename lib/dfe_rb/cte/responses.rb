module DfeRb
  module Cte
    class Response < DfeRb::Response
      NAMESPACE = Signature::CTE
    end

    Protocol = Data.define(:key, :code, :message, :number, :received_at, :digest_value, :alerts, :xml) do
      def self.parse(element_xml)
        parsed = Response.new(element_xml)
        new(
          key: parsed.text("infProt/chCTe"),
          code: parsed.text("infProt/cStat")&.to_i,
          message: parsed.text("infProt/xMotivo"),
          number: parsed.text("infProt/nProt"),
          received_at: parsed.text("infProt/dhRecbto"),
          digest_value: parsed.text("infProt/digVal"),
          alerts: parsed.nodes("infFisco").map { |node| {code: node.at_xpath("cMsg")&.text, message: node.at_xpath("xMsg")&.text} },
          xml: element_xml
        )
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
