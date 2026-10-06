module DfeRb
  module Nfe
    # The XML each web service takes. Values are escaped; the signed documents (NFe, evento,
    # inutNFe) are inserted untouched.
    module Requests
      NS = Signature::NFE

      CORRECTION_TERMS = "A Carta de Correcao e disciplinada pelo paragrafo 1o-A do art. 7o do Convenio S/N, de 15 de " \
        "dezembro de 1970 e pode ser utilizada para regularizacao de erro ocorrido na emissao de documento fiscal, desde " \
        "que o erro nao esteja relacionado com: I - as variaveis que determinam o valor do imposto tais como: base de " \
        "calculo, aliquota, diferenca de preco, quantidade, valor da operacao ou da prestacao; II - a correcao de dados " \
        "cadastrais que implique mudanca do remetente ou do destinatario; III - a data de emissao ou de saida."

      module_function

      def escape(text) = text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")

      def status(state:, environment:)
        %(<consStatServ xmlns="#{NS}" versao="4.00"><tpAmb>#{Environment.code(environment)}</tpAmb>) +
          %(<cUF>#{States.code(state)}</cUF><xServ>STATUS</xServ></consStatServ>)
      end

      # `signed` are signed <NFe> strings. A single-note lot is synchronous (mandatory since
      # 13/10/2025); larger lots are processed asynchronously and return a receipt.
      def authorization(signed, lot_id:, sync:)
        %(<enviNFe xmlns="#{NS}" versao="4.00"><idLote>#{lot_id}</idLote><indSinc>#{sync ? 1 : 0}</indSinc>#{signed.join}</enviNFe>)
      end

      def lot_return(receipt:, environment:)
        %(<consReciNFe xmlns="#{NS}" versao="4.00"><tpAmb>#{Environment.code(environment)}</tpAmb><nRec>#{receipt}</nRec></consReciNFe>)
      end

      def consult(key:, environment:)
        %(<consSitNFe xmlns="#{NS}" versao="4.00"><tpAmb>#{Environment.code(environment)}</tpAmb>) +
          %(<xServ>CONSULTAR</xServ><chNFe>#{key}</chNFe></consSitNFe>)
      end

      # An unsigned <evento> for the note `key`. `detail` is the inside of <detEvento>.
      # `agency` is who registers it (cOrgao): the note's state, or 91 for the Ambiente Nacional.
      def event(key:, type:, sequence:, detail:, environment:, at:, agency: key.state_code)
        issuer = key.tax_id.start_with?("000") ? key.tax_id[3..] : key.tax_id
        tax_tag = (issuer.length == 11) ? "CPF" : "CNPJ"
        id = "ID#{type}#{key}#{format("%02d", sequence)}"
        %(<evento xmlns="#{NS}" versao="1.00"><infEvento Id="#{id}"><cOrgao>#{agency}</cOrgao>) +
          %(<tpAmb>#{Environment.code(environment)}</tpAmb><#{tax_tag}>#{issuer}</#{tax_tag}><chNFe>#{key}</chNFe>) +
          %(<dhEvento>#{at.strftime("%Y-%m-%dT%H:%M:%S%:z")}</dhEvento><tpEvento>#{type}</tpEvento>) +
          %(<nSeqEvento>#{sequence}</nSeqEvento><verEvento>1.00</verEvento><detEvento versao="1.00">#{detail}</detEvento>) +
          %(</infEvento></evento>)
      end

      def cancellation_detail(protocol:, reason:)
        %(<descEvento>Cancelamento</descEvento><nProt>#{protocol}</nProt><xJust>#{escape(reason)}</xJust>)
      end

      def correction_detail(text:)
        %(<descEvento>Carta de Correcao</descEvento><xCorrecao>#{escape(text)}</xCorrecao><xCondUso>#{CORRECTION_TERMS}</xCondUso>)
      end

      # <ConsCad> for one taxpayer of `state`, by exactly one of its identifiers.
      def registry(state:, cnpj: nil, cpf: nil, ie: nil)
        given = {"IE" => ie, "CNPJ" => cnpj, "CPF" => cpf}.reject { |_, value| value.to_s.strip.empty? }
        raise ArgumentError, "give one of cnpj:, cpf: or ie: (got #{given.size})" unless given.size == 1

        tag, value = given.first
        value = (tag == "IE") ? value.to_s.gsub(/[.\-\/\s]/, "").upcase : TaxId.normalize(value)
        %(<ConsCad xmlns="#{NS}" versao="2.00"><infCons><xServ>CONS-CAD</xServ><UF>#{States.abbreviation(state)}</UF>) +
          %(<#{tag}>#{escape(value)}</#{tag}></infCons></ConsCad>)
      end

      def event_batch(signed_events, lot_id:)
        %(<envEvento xmlns="#{NS}" versao="1.00"><idLote>#{lot_id}</idLote>#{signed_events.join}</envEvento>)
      end

      # An unsigned <inutNFe>.
      def inutilization(state:, year:, tax_id:, model:, series:, from:, to:, reason:, environment:)
        id = "ID#{States.code(state)}#{format("%02d", year % 100)}#{TaxId.normalize(tax_id).rjust(14, "0")}" \
          "#{format("%02d", model)}#{format("%03d", series)}#{format("%09d", from)}#{format("%09d", to)}"
        %(<inutNFe xmlns="#{NS}" versao="4.00"><infInut Id="#{id}"><tpAmb>#{Environment.code(environment)}</tpAmb>) +
          %(<xServ>INUTILIZAR</xServ><cUF>#{States.code(state)}</cUF><ano>#{format("%02d", year % 100)}</ano>) +
          %(<CNPJ>#{TaxId.normalize(tax_id)}</CNPJ><mod>#{model}</mod><serie>#{series}</serie><nNFIni>#{from}</nNFIni>) +
          %(<nNFFin>#{to}</nNFFin><xJust>#{escape(reason)}</xJust></infInut></inutNFe>)
      end
    end
  end
end
