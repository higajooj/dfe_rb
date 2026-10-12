module DfeRb
  module Mdfe
    # A SEFAZ answer about an MDF-e (DfeRb::Response).
    class Response < DfeRb::Response
      NAMESPACE = Signature::MDFE
    end

    # The protocol SEFAZ returned for a manifest: its authorization, or the rejection.
    Protocol = Data.define(:key, :code, :message, :number, :received_at, :digest_value, :alerts, :xml) do
      def self.parse(element_xml)
        parsed = Response.new(element_xml)
        new(
          key: parsed.text("infProt/chMDFe"), code: parsed.text("infProt/cStat")&.to_i, message: parsed.text("infProt/xMotivo"),
          number: parsed.text("infProt/nProt"), received_at: parsed.text("infProt/dhRecbto"), digest_value: parsed.text("infProt/digVal"),
          alerts: parsed.nodes("infFisco").map { |node| {code: node.at_xpath("cMsg")&.text, message: node.at_xpath("xMsg")&.text} },
          xml: element_xml
        )
      end
    end

    # Builds mdfeProc and procEventoMDFe: the signed document plus SEFAZ's answer, which are
    # the files to archive. The signed document goes in untouched.
    module Proc
      DECLARATION = %(<?xml version="1.0" encoding="UTF-8"?>).freeze

      module_function

      def mdfe(signed_mdfe, protocol_xml, version: Schema::VERSION)
        %(#{DECLARATION}<mdfeProc xmlns="#{Signature::MDFE}" versao="#{version}">#{signed_mdfe}#{protocol_xml}</mdfeProc>)
      end

      def event(signed_event, return_xml, version: Schema::VERSION)
        %(#{DECLARATION}<procEventoMDFe xmlns="#{Signature::MDFE}" versao="#{version}">#{signed_event}#{return_xml}</procEventoMDFe>)
      end
    end
  end
end
