require "base64"
require "stringio"
require "zlib"

module DfeRb
  module Mdfe
    # The XML each web service takes. Values are escaped. The signed documents (MDFe,
    # eventoMDFe) are inserted untouched.
    module Requests
      NS = Signature::MDFE
      VERSION = Schema::VERSION

      module_function

      def escape(text) = text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")

      def status(environment:)
        %(<consStatServMDFe xmlns="#{NS}" versao="#{VERSION}"><tpAmb>#{Environment.code(environment)}</tpAmb><xServ>STATUS</xServ></consStatServMDFe>)
      end

      # What MDFeRecepcaoSinc takes: the signed <MDFe> compressed with GZip, in Base64 (MOC 3.4.1).
      def authorization(signed_mdfe)
        buffer = StringIO.new("".b)
        gzip = Zlib::GzipWriter.new(buffer)
        gzip.write(signed_mdfe)
        gzip.close
        Base64.strict_encode64(buffer.string)
      end

      # The <MDFe> inside an authorization payload.
      def unpack(payload)
        Zlib::GzipReader.new(StringIO.new(Base64.strict_decode64(payload))).read.force_encoding(Encoding::UTF_8)
      end

      def consult(key:, environment:)
        %(<consSitMDFe xmlns="#{NS}" versao="#{VERSION}"><tpAmb>#{Environment.code(environment)}</tpAmb>) +
          %(<xServ>CONSULTAR</xServ><chMDFe>#{key}</chMDFe></consSitMDFe>)
      end

      # The manifests of `tax_id` (a CNPJ or CPF) still open.
      def unclosed(tax_id:, environment:)
        id = TaxId.normalize(tax_id)
        tag = (id.length == 11) ? "CPF" : "CNPJ"
        %(<consMDFeNaoEnc xmlns="#{NS}" versao="#{VERSION}"><tpAmb>#{Environment.code(environment)}</tpAmb>) +
          %(<xServ>CONSULTAR NÃO ENCERRADOS</xServ><#{tag}>#{id}</#{tag}></consMDFeNaoEnc>)
      end

      # An unsigned <eventoMDFe> for the manifest `key`. `detail` is the event's own element
      # (evCancMDFe...), which goes inside <detEvento>. The author is the key's issuer.
      def event(key:, type:, sequence:, detail:, environment:, at:)
        issuer = key.issuer_id
        tax_tag = key.person? ? "CPF" : "CNPJ"
        id = "ID#{type}#{key}#{format("%02d", sequence)}"
        %(<eventoMDFe xmlns="#{NS}" versao="#{VERSION}"><infEvento Id="#{id}"><cOrgao>#{key.state_code}</cOrgao>) +
          %(<tpAmb>#{Environment.code(environment)}</tpAmb><#{tax_tag}>#{issuer}</#{tax_tag}><chMDFe>#{key}</chMDFe>) +
          %(<dhEvento>#{at.strftime("%Y-%m-%dT%H:%M:%S%:z")}</dhEvento><tpEvento>#{type}</tpEvento>) +
          %(<nSeqEvento>#{sequence}</nSeqEvento><detEvento versaoEvento="#{VERSION}">#{detail}</detEvento>) +
          %(</infEvento></eventoMDFe>)
      end

      def cancellation(protocol:, reason:)
        %(<evCancMDFe><descEvento>Cancelamento</descEvento><nProt>#{protocol}</nProt><xJust>#{escape(reason)}</xJust></evCancMDFe>)
      end

      # city_code is where the trip ended (9999999 abroad) and state_code its state (99 abroad).
      def closing(protocol:, on:, state_code:, city_code:)
        %(<evEncMDFe><descEvento>Encerramento</descEvento><nProt>#{protocol}</nProt><dtEnc>#{on.strftime("%Y-%m-%d")}</dtEnc>) +
          %(<cUF>#{state_code}</cUF><cMun>#{city_code}</cMun></evEncMDFe>)
      end

      def driver(name:, cpf:)
        %(<evIncCondutorMDFe><descEvento>Inclusao Condutor</descEvento><condutor><xNome>#{escape(name)}</xNome>) +
          %(<CPF>#{cpf}</CPF></condutor></evIncCondutorMDFe>)
      end

      # loading and each document's unloading are [IBGE code, name]; documents are
      # [[unloading, NF-e key], ...].
      def documents(protocol:, loading:, documents:)
        listed = documents.map do |(code, name), key|
          %(<infDoc><cMunDescarga>#{code}</cMunDescarga><xMunDescarga>#{escape(name)}</xMunDescarga><chNFe>#{key}</chNFe></infDoc>)
        end
        %(<evIncDFeMDFe><descEvento>Inclusao DF-e</descEvento><nProt>#{protocol}</nProt><cMunCarrega>#{loading[0]}</cMunCarrega>) +
          %(<xMunCarrega>#{escape(loading[1])}</xMunCarrega>#{listed.join}</evIncDFeMDFe>)
      end
    end
  end
end
