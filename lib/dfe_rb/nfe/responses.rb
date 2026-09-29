require "nokogiri"

module DfeRb
  module Nfe
    # Reads SEFAZ answers. Element lookups ignore namespaces; fragments that must be kept
    # (protNFe, retEvento...) are copied with their namespace declarations intact.
    class Response
      NS = {"nfe" => Signature::NFE}.freeze

      attr_reader :xml, :plain

      def initialize(xml)
        @xml = xml
        @namespaced = Nokogiri::XML(xml)
        @plain = Nokogiri::XML(xml).tap(&:remove_namespaces!)
      end

      def root_name = @plain.root&.name

      # Text of the first element matching the CSS/XPath-free tag path, e.g. "infProt/cStat".
      def text(path, from: @plain)
        from.at_xpath("//" + path.split("/").join("/"))&.text&.strip
      end

      def code = text("cStat")&.to_i

      def message = text("xMotivo")

      # A copy of the first `tag` element, namespaces preserved, as XML.
      def fragment(tag, from: @namespaced)
        node = from.at_xpath("//nfe:#{tag}", NS) or return
        node.dup.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
      end

      def fragments(tag)
        @namespaced.xpath("//nfe:#{tag}", NS).map do |node|
          node.dup.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
        end
      end

      def nodes(tag) = @plain.xpath("//#{tag}")
    end

    # One NF-e's outcome from an authorization request: the protocol SEFAZ returned for it, or
    # the rejection.
    Protocol = Data.define(:key, :code, :message, :number, :received_at, :digest_value, :alerts, :xml) do
      def self.parse(element_xml)
        parsed = Response.new(element_xml)
        new(
          key: parsed.text("chNFe"), code: parsed.text("cStat")&.to_i, message: parsed.text("xMotivo"),
          number: parsed.text("nProt"), received_at: parsed.text("dhRecbto"), digest_value: parsed.text("digVal"),
          alerts: parsed.nodes("infProt/cMsg").zip(parsed.nodes("infProt/xMsg")).map do |code, text|
            {code: code.text, message: text&.text}
          end,
          xml: element_xml
        )
      end
    end

    # nfeProc, procEventoNFe and ProcInutNFe: the signed document plus SEFAZ's answer, the
    # files to archive and send to the recipient. The signed document goes in untouched.
    module Proc
      DECLARATION = %(<?xml version="1.0" encoding="UTF-8"?>).freeze

      module_function

      def nfe(signed_nfe, protocol_xml, version: "4.00")
        %(#{DECLARATION}<nfeProc xmlns="#{Signature::NFE}" versao="#{version}">#{signed_nfe}#{protocol_xml}</nfeProc>)
      end

      def event(signed_event, return_event_xml, version: "1.00")
        %(#{DECLARATION}<procEventoNFe xmlns="#{Signature::NFE}" versao="#{version}">#{signed_event}#{return_event_xml}</procEventoNFe>)
      end

      def inutilization(signed_request, return_xml, version: "4.00")
        %(#{DECLARATION}<ProcInutNFe xmlns="#{Signature::NFE}" versao="#{version}">#{signed_request}#{return_xml}</ProcInutNFe>)
      end
    end
  end
end
