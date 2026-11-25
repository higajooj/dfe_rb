require "base64"
require "digest"
require "stringio"
require "zlib"

module DfeRb
  module Cte
    module Requests
      NS = Signature::CTE
      VERSION = Schema::VERSION
      CCE_TERMS = "A Carta de Correcao e disciplinada pelo Art. 58-B do CONVENIO/SINIEF 06/89: " \
        "Fica permitida a utilizacao de carta de correcao, para regularizacao de erro ocorrido na emissao de " \
        "documentos fiscais relativos a prestacao de servico de transporte, desde que o erro nao esteja " \
        "relacionado com: I - as variaveis que determinam o valor do imposto tais como: base de calculo, " \
        "aliquota, diferenca de preco, quantidade, valor da prestacao;II - a correcao de dados cadastrais que " \
        "implique mudanca do emitente, tomador, remetente ou do destinatario;III - a data de emissao ou de saida."
      PRESUMED_CREDIT_DECLARATION = "Declaro, para fins de apropriacao do credito presumido solicitado, " \
        "relativo a operacao registrada no documento fiscal eletronico a que se refere este evento: " \
        "I – ja ter efetuado o pagamento integral do valor da prestacao do servico ao transportador, " \
        "nos termos do art. 126, paragrafo 5o, II, da Lei Complementar no 214, de 16 de janeiro de 2025; " \
        "II – estar ciente de que a prestacao de declaracao falsa sujeita-me as penalidades administrativas " \
        "e sancoes penais previstas na legislacao, sem prejuizo do estorno do credito indevidamente apropriado " \
        "com os acrescimos legais.".freeze
      DELIVERY_FAILURE_REASONS = {
        recipient_not_found: "1",
        refused: "2",
        address_not_found: "3",
        other: "4"
      }.freeze
      CCE_FORBIDDEN = {
        "infCte" => %w[versao Id],
        "ide" => %w[cUF cCT mod serie nCT tpEmis cDV tpAmb dhEmi modal CFOP cMunIni],
        "toma3" => %w[toma],
        "toma4" => %w[CNPJ CPF IE],
        "enderToma" => %w[UF],
        "emit" => %w[CNPJ IE],
        "rem" => %w[CNPJ CPF IE],
        "enderReme" => %w[UF],
        "dest" => %w[CNPJ CPF IE],
        "enderDest" => %w[UF],
        "enderReceb" => %w[UF],
        "enderExped" => %w[UF],
        "vPrest" => %w[vTPrest],
        "Comp" => %w[vComp],
        "vPresComp" => %w[vTPrest],
        "compComp" => %w[vComp],
        "infNFe" => %w[chave],
        "ICMS00" => %w[CST vBC pICMS vICMS],
        "ICMS20" => %w[CST pRedBC vBC pICMS vICMS cBenef],
        "ICMS45" => %w[CST cBenef],
        "ICMS60" => %w[CST vBCSTRet vICMSSTRet pICMSSTRet vCred cBenef],
        "ICMS90" => %w[CST pRedBC vBC pICMS vICMS vCred cBenef],
        "ICMSOutraUF" => %w[CST pRedBCOutraUF vBCOutraUF pICMSOutraUF vICMSOutraUF cBenef],
        "ICMSSN" => %w[indSN CST]
      }.freeze

      module_function

      def escape(text) = text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")

      def escape_attr(text) = escape(text).gsub('"', "&quot;")

      def status(state:, environment:)
        %(<consStatServCTe xmlns="#{NS}" versao="#{VERSION}"><tpAmb>#{Environment.code(environment)}</tpAmb>) +
          %(<cUF>#{DfeRb::States.code(state)}</cUF><xServ>STATUS</xServ></consStatServCTe>)
      end

      def authorization(signed_cte)
        buffer = StringIO.new("".b)
        gzip = Zlib::GzipWriter.new(buffer)
        gzip.write(signed_cte)
        gzip.close
        Base64.strict_encode64(buffer.string)
      end

      def unpack(payload)
        Zlib::GzipReader.new(StringIO.new(Base64.strict_decode64(payload))).read.force_encoding(Encoding::UTF_8)
      end

      def consult(key:, environment:)
        %(<consSitCTe xmlns="#{NS}" versao="#{VERSION}"><tpAmb>#{Environment.code(environment)}</tpAmb>) +
          %(<xServ>CONSULTAR</xServ><chCTe>#{key}</chCTe></consSitCTe>)
      end

      def event(key:, type:, sequence:, detail:, environment:, at:, author: nil)
        actor = author ? TaxId.normalize(author) : key.issuer_id
        tax_tag = (actor.length == 11) ? "CPF" : "CNPJ"
        id = "ID#{type}#{key}#{format("%03d", sequence)}"
        %(<eventoCTe xmlns="#{NS}" versao="#{VERSION}"><infEvento Id="#{id}"><cOrgao>#{key.state_code}</cOrgao>) +
          %(<tpAmb>#{Environment.code(environment)}</tpAmb><#{tax_tag}>#{actor}</#{tax_tag}><chCTe>#{key}</chCTe>) +
          %(<dhEvento>#{format_time(at)}</dhEvento><tpEvento>#{type}</tpEvento>) +
          %(<nSeqEvento>#{sequence}</nSeqEvento><detEvento versaoEvento="#{VERSION}">#{detail}</detEvento>) +
          %(</infEvento></eventoCTe>)
      end

      def cancellation(protocol:, reason:)
        %(<evCancCTe><descEvento>Cancelamento</descEvento><nProt>#{protocol}</nProt><xJust>#{escape(reason)}</xJust></evCancCTe>)
      end

      def correction(changes:)
        items = changes.map do |change|
          item = change.transform_keys(&:to_sym)
          group = item.fetch(:group).to_s.strip
          field = item.fetch(:field).to_s.strip
          value = Formatter.sanitize(item.fetch(:value))
          if forbidden_cce_field?(group, field)
            raise ArgumentError, "#{group}/#{field} cannot be changed by Carta de Correção (MOC 13.1, rej. 681)"
          end
          index_tag = if item[:item_number]
            idx = item[:item_number].to_i
            raise ArgumentError, "item_number must be between 1 and 99 (rej. 522)" unless (1..99).cover?(idx)

            "<nroItemAlterado>#{format("%02d", idx)}</nroItemAlterado>"
          end
          %(<infCorrecao><grupoAlterado>#{escape(group)}</grupoAlterado><campoAlterado>#{escape(field)}</campoAlterado>) +
            %(<valorAlterado>#{escape(value)}</valorAlterado>#{index_tag}</infCorrecao>)
        end
        %(<evCCeCTe><descEvento>Carta de Correcao</descEvento>#{items.join}<xCondUso>#{CCE_TERMS}</xCondUso></evCCeCTe>)
      end

      def forbidden_cce_field?(group, field)
        CCE_FORBIDDEN.any? { |g, fields| g.casecmp?(group) && fields.any? { |f| f.casecmp?(field) } }
      end

      def disagreement(reason:)
        %(<evPrestDesacordo><descEvento>Prestacao do Servico em Desacordo</descEvento><indDesacordoOper>1</indDesacordoOper>) +
          %(<xObs>#{escape(reason)}</xObs></evPrestDesacordo>)
      end

      def cancel_disagreement(protocol:)
        %(<evCancPrestDesacordo><descEvento>Cancelamento Prestacao do Servico em Desacordo</descEvento>) +
          %(<nProtEvPrestDes>#{protocol}</nProtEvPrestDes></evCancPrestDesacordo>)
      end

      def delivery_hash(key:, image:)
        Base64.strict_encode64(Digest::SHA1.digest("#{key}#{Base64.strict_encode64(image)}"))
      end

      def delivery_receipt(protocol:, delivered_at:, document:, name:, hash:, hashed_at:, latitude: nil, longitude: nil, nfe_keys: [])
        coords = +""
        coords << "<latitude>#{latitude}</latitude>" if latitude
        coords << "<longitude>#{longitude}</longitude>" if longitude
        deliveries = Array(nfe_keys).map { |k| "<infEntrega><chNFe>#{k}</chNFe></infEntrega>" }.join
        %(<evCECTe><descEvento>Comprovante de Entrega do CT-e</descEvento><nProt>#{protocol}</nProt>) +
          %(<dhEntrega>#{format_time(delivered_at)}</dhEntrega><nDoc>#{escape(document)}</nDoc>) +
          %(<xNome>#{escape(name)}</xNome>#{coords}<hashEntrega>#{hash}</hashEntrega>) +
          %(<dhHashEntrega>#{format_time(hashed_at)}</dhHashEntrega>#{deliveries}</evCECTe>)
      end

      def cancel_delivery_receipt(protocol:, event_protocol:)
        %(<evCancCECTe><descEvento>Cancelamento do Comprovante de Entrega do CT-e</descEvento>) +
          %(<nProt>#{protocol}</nProt><nProtCE>#{event_protocol}</nProtCE></evCancCECTe>)
      end

      def delivery_failure(protocol:, attempted_at:, reason:, justification: nil, attempt: nil, hash: nil, hashed_at: nil,
        latitude: nil, longitude: nil, nfe_keys: [])
        reason_code = reason.is_a?(Symbol) ? DELIVERY_FAILURE_REASONS.fetch(reason) { raise ArgumentError, "unknown delivery failure reason #{reason.inspect}" } : reason.to_s
        xml = %(<evIECTe><descEvento>Insucesso na Entrega do CT-e</descEvento><nProt>#{protocol}</nProt>)
        xml << %(<dhTentativaEntrega>#{format_time(attempted_at)}</dhTentativaEntrega>)
        xml << %(<nTentativa>#{format("%03d", attempt.to_i)}</nTentativa>) if attempt
        xml << %(<tpMotivo>#{reason_code}</tpMotivo>)
        xml << %(<xJustMotivo>#{escape(justification)}</xJustMotivo>) if justification
        xml << %(<latitude>#{latitude}</latitude>) if latitude
        xml << %(<longitude>#{longitude}</longitude>) if longitude
        xml << %(<hashTentativaEntrega>#{hash}</hashTentativaEntrega>) if hash
        xml << %(<dhHashTentativaEntrega>#{format_time(hashed_at)}</dhHashTentativaEntrega>) if hashed_at
        Array(nfe_keys).each { |k| xml << "<infEntrega><chNFe>#{k}</chNFe></infEntrega>" }
        xml << "</evIECTe>"
      end

      def cancel_delivery_failure(protocol:, event_protocol:)
        %(<evCancIECTe><descEvento>Cancelamento do Insucesso de Entrega do CT-e</descEvento>) +
          %(<nProt>#{protocol}</nProt><nProtIE>#{event_protocol}</nProtIE></evCancIECTe>)
      end

      def multimodal_record(text:, document: nil)
        doc_tag = document ? "<nDoc>#{escape(document)}</nDoc>" : ""
        %(<evRegMultimodal><descEvento>Registro Multimodal</descEvento><xRegistro>#{escape(text)}</xRegistro>#{doc_tag}</evRegMultimodal>)
      end

      def payment_link(protocol:, number:, transaction_id:, method:, receiver_cnpj:, psp_cnpj_base:)
        method_code = method.is_a?(Symbol) ? Names.enum_value("tpMeioPgto", method) : method.to_s.rjust(2, "0")
        %(<evVincPgto><descEvento>Vinculacao do Pagamento</descEvento><nProt>#{protocol}</nProt>) +
          %(<pgto nPag="#{number.to_i}" idTransacao="#{escape_attr(transaction_id)}">) +
          %(<tpMeioPgto>#{method_code}</tpMeioPgto><CNPJReceb>#{TaxId.normalize(receiver_cnpj)}</CNPJReceb>) +
          %(<CNPJBasePSP>#{TaxId.normalize(psp_cnpj_base)}</CNPJBasePSP></pgto></evVincPgto>)
      end

      def cancel_payment_link(protocol:, event_protocol:)
        %(<evCancVincPgto><descEvento>Cancelamento da vinculacao do pagamento</descEvento>) +
          %(<nProt>#{protocol}</nProt><nProtVincPgto>#{event_protocol}</nProtVincPgto></evCancVincPgto>)
      end

      def presumed_credit(base:, code:, ibs: nil, cbs: nil, payment_declaration: nil)
        xml = %(<evApropriaCredPres><descEvento>Apropriacao Credito Presumido</descEvento>)
        xml << %(<vBCCredPres>#{format("%.2f", base)}</vBCCredPres><cCredPres>#{code}</cCredPres>)
        if ibs
          xml << %(<gIBSCredPres><pCredPres>#{format_rate(ibs[:rate])}</pCredPres>)
          xml << %(<vCredPres>#{format("%.2f", ibs[:amount])}</vCredPres></gIBSCredPres>)
        end
        if cbs
          xml << %(<gCBSCredPres><pCredPres>#{format_rate(cbs[:rate])}</pCredPres>)
          xml << %(<vCredPres>#{format("%.2f", cbs[:amount])}</vCredPres></gCBSCredPres>)
        end
        xml << %(<xDecPag>#{escape(payment_declaration)}</xDecPag>) if payment_declaration
        xml << "</evApropriaCredPres>"
      end

      def format_rate(value)
        formatted = format("%.4f", value).sub(/0+\z/, "")
        integer, decimals = formatted.split(".", 2)
        "#{integer}.#{(decimals || "").ljust(2, "0")}"
      end

      def format_time(value)
        return value.to_time.strftime("%Y-%m-%dT%H:%M:%S%:z") if value.is_a?(DateTime)
        return value.strftime("%Y-%m-%dT%H:%M:%S%:z") if value.respond_to?(:strftime)

        value.to_s
      end
    end
  end
end
