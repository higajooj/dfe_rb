require "base64"
require "stringio"
require "zlib"

module DfeRb
  module Nfse
    # What the Sefin Nacional's API takes and returns: XML compressed with GZip in Base64
    # inside JSON, and the request to register an event (pedRegEvento, Anexo II).
    module Requests
      # Event code => [element, xDesc]. The descriptions are fixed by the schema.
      EVENTS = {
        "101101" => ["e101101", "Cancelamento de NFS-e"],
        "101103" => ["e101103", "Solicitação de Análise Fiscal para Cancelamento de NFS-e"],
        "202201" => ["e202201", "Manifestação de NFS-e - Confirmação do Prestador"],
        "203202" => ["e203202", "Manifestação de NFS-e - Confirmação do Tomador"],
        "204203" => ["e204203", "Manifestação de NFS-e - Confirmação do Intermediário"],
        "202205" => ["e202205", "Manifestação de NFS-e - Rejeição do Prestador"],
        "203206" => ["e203206", "Manifestação de NFS-e - Rejeição do Tomador"],
        "204207" => ["e204207", "Manifestação de NFS-e - Rejeição do Intermediário"]
      }.freeze

      module_function

      def escape(text) = text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")

      DECLARATION = %(<?xml version="1.0" encoding="UTF-8"?>)

      # `xml` compressed with GZip, in Base64: dpsXmlGZipB64, pedidoRegistroEventoXmlGZipB64.
      # The document goes with the XML declaration naming UTF-8, without which the Sefin
      # refuses it (E1229).
      def pack(xml)
        buffer = StringIO.new("".b)
        gzip = Zlib::GzipWriter.new(buffer)
        gzip.write(DECLARATION + xml.to_s.sub(/\A\s*<\?xml[^>]*\?>\s*/, ""))
        gzip.close
        Base64.strict_encode64(buffer.string)
      end

      # The XML inside nfseXmlGZipB64, eventoXmlGZipB64 or a distributed ArquivoXml.
      def unpack(payload)
        Zlib::GzipReader.new(StringIO.new(Base64.decode64(payload.to_s))).read.force_encoding(Encoding::UTF_8)
      rescue Zlib::Error => e
        raise TransportError.new("the document in the answer is not GZip in Base64: #{e.message}", maybe_processed: true)
      end

      # An unsigned <pedRegEvento> for the note `key`: Id "PRE" + key + the event code.
      # `author` is the CNPJ or CPF of whom registers it; `detail` the event's own children.
      def event(key:, type:, author:, detail:, environment:, at:, version:)
        element, description = EVENTS.fetch(type)
        id = TaxId.normalize(author)
        tag = (id.length == 11) ? "CPFAutor" : "CNPJAutor"
        %(<pedRegEvento xmlns="#{NAMESPACE}" versao="#{version}"><infPedReg Id="PRE#{key}#{type}">) +
          %(<tpAmb>#{Environment.code(environment)}</tpAmb><verAplic>#{escape("dfe_rb #{DfeRb::VERSION}")}</verAplic>) +
          %(<dhEvento>#{at.strftime("%Y-%m-%dT%H:%M:%S%:z")}</dhEvento><#{tag}>#{id}</#{tag}><chNFSe>#{key}</chNFSe>) +
          %(<#{element}><xDesc>#{escape(description)}</xDesc>#{detail}</#{element}></infPedReg></pedRegEvento>)
      end

      # cMotivo and, when given, xMotivo: the detail of a cancellation or a rejection.
      def reason(code:, text:)
        %(<cMotivo>#{code}</cMotivo>) + (text ? %(<xMotivo>#{escape(text)}</xMotivo>) : "")
      end
    end
  end
end
