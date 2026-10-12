require "nokogiri"

module DfeRb
  module Nfe
    # A SEFAZ answer about an NF-e (DfeRb::Response).
    class Response < DfeRb::Response
      NAMESPACE = Signature::NFE
      NS = {"nfe" => NAMESPACE}.freeze
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

    # Builds nfeProc, procEventoNFe and ProcInutNFe: the signed document plus SEFAZ's answer,
    # which are the files to archive and send to the recipient. The signed document goes in
    # untouched.
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
