require "base64"
require "bigdecimal"
require "date"
require "digest"
require "time"

module DfeRb
  module Nfe
    # Completes an invoice: fills the defaults a developer shouldn't have to spell out and
    # derives what follows from other fields (access key, destination indicator, totals...).
    # Anything the developer set explicitly is kept.
    class Resolver
      HOMOLOGACAO_RECIPIENT_NAME = "NF-E EMITIDA EM AMBIENTE DE HOMOLOGACAO - SEM VALOR FISCAL"
      # First CFOP digit by tpNF and idDest (RVs I08-*, rej. 731-733).
      CFOP_PREFIX = {
        "0" => {"1" => "1", "2" => "2", "3" => "3"},
        "1" => {"1" => "5", "2" => "6", "3" => "7"}
      }.freeze
      # tPag 90 (sem pagamento) and 91 (pagamento posterior) carry vPag 0.00 (RV YA03-30).
      DEFERRED_PAYMENT_KINDS = Tables::DEFERRED_PAYMENTS

      # Values that must stay the same across resolves of one invoice (a retry must never
      # produce another cNF or emission time). Held by the Invoice.
      Memo = Struct.new(:numeric_code, :issued_at)

      # Problems that stopped a field from being derived (the access key needs a valid
      # emission date, series and number), as validation messages.
      attr_reader :issues

      # csrt: the Código de Segurança do Responsável Técnico, which signs infRespTec/hashCSRT
      # and never goes into the XML.
      def initialize(environment:, memo:, clock: Time, csrt: nil)
        @environment = Environment.normalize(environment)
        @memo = memo
        @clock = clock
        @csrt = csrt
        @issues = []
      end

      # `infNFe` (tag-keyed Hash) => a resolved copy.
      def call(infnfe)
        @issues = []
        inf = Marshal.load(Marshal.dump(infnfe))
        normalize(inf, Schema.nfe.find("infNFe"))
        ide = (inf["ide"] ||= {})
        emit = inf["emit"] || {}
        addresses(inf)
        state = emit.dig("enderEmit", "UF")

        defaults(ide, emit, state, Array(inf["det"]))
        recipient(inf, ide, state)
        items(inf, ide, state)
        inf["transp"] ||= {}
        inf["transp"]["modFrete"] = 9 if inf["transp"]["modFrete"].nil?
        totals(inf)
        billing(inf)
        identify(inf, ide, emit)
        technical_contact(inf)
        inf
      end

      private

      # Formatted codes typed by a person ("11.222.333/0001-81") become what the layout takes.
      def normalize(data, element)
        element.each_element do |child|
          next unless data.key?(child.tag)

          value = data[child.tag]
          if child.leaf? && child.type
            data[child.tag] = value.is_a?(Array) ? value.map { |item| Formatter.forgive(item, child) } : Formatter.forgive(value, child)
          else
            (value.is_a?(Array) ? value : [value]).each { |entry| normalize(entry, child) if entry.is_a?(Hash) }
          end
        end
      end

      # A city code gives its state and name; a name and state give the code (IBGE table).
      def addresses(inf)
        [inf.dig("emit", "enderEmit"), inf.dig("dest", "enderDest"), inf["retirada"], inf["entrega"]].each do |address|
          next unless address.is_a?(Hash)

          code = address["cMun"].to_s
          address["UF"] ||= States::CODES.key(code[0, 2].to_i) if code.match?(/\A\d{7}\z/)
          next if address["UF"] == "EX"

          address["xMun"] ||= Tables.city_name(code) unless code.empty?
          address["cMun"] ||= Tables.city_code(address["xMun"], address["UF"]) if address["xMun"] && address["UF"]
        end
      end

      def defaults(ide, emit, state, det)
        ide["cUF"] ||= States.code(state) if state
        ide["mod"] ||= 55
        ide["serie"] ||= 1
        # A credit or debit note type fixes finNFe (RV B25.1-10, B25.2-10); a credit note is
        # an entry (B25-110) and a debit note an exit (B25-120). Any other note whose CFOPs
        # are all entries is an entry (I08-10).
        ide["finNFe"] ||= if ide["tpNFCredito"]
          5
        elsif ide["tpNFDebito"]
          6
        else
          1
        end
        ide["tpNF"] ||= case ide["finNFe"].to_s
        when "5" then 0
        when "6" then 1
        else entry_cfops?(det) ? 0 : 1
        end
        ide["cMunFG"] ||= emit.dig("enderEmit", "cMun")
        ide["tpImp"] ||= 1
        ide["tpEmis"] = States.contingency_emission_type(state) if ide["tpEmis"] == :svc && state
        ide["tpEmis"] ||= 1
        ide["dhCont"] = ide["dhCont"].to_time if ide["dhCont"].is_a?(DateTime)
        ide["tpAmb"] ||= Environment.code(@environment)
        ide["indPres"] ||= 1
        ide["procEmi"] ||= 0
        ide["verProc"] ||= "dfe_rb #{DfeRb::VERSION}"
        ide["indIntermed"] ||= 0 if [2, 3, 4, 9].include?(ide["indPres"].to_i)
        # A copy, so nothing done to the tree can change the memoized time.
        ide["dhEmi"] ||= (@memo.issued_at ||= now_in(state)).dup
        ide["dhEmi"] = ide["dhEmi"].to_time if ide["dhEmi"].is_a?(DateTime)
        ide["cNF"] ||= (@memo.numeric_code ||= AccessKey.generate_numeric_code(number: ide["nNF"]))
      end

      # Every item has a full CFOP of entry (1xxx, 2xxx, 3xxx). A 3-digit CFOP takes its
      # first digit from tpNF, so it can't decide it.
      def entry_cfops?(det)
        det.any? && det.all? { |item| Tables.cfop(item.dig("prod", "CFOP").to_s[/\A\d{4}\z/])&.entry? }
      end

      def now_in(state)
        state ? States.now(state, @clock) : @clock.now.getlocal(States::DEFAULT_UTC_OFFSET)
      end

      def recipient(inf, ide, state)
        dest = inf["dest"]
        unless dest
          ide["idDest"] ||= 1
          ide["indFinal"] ||= 0
          return
        end

        dest["xNome"] = HOMOLOGACAO_RECIPIENT_NAME if @environment == Environment::HOMOLOGACAO
        foreign = dest["idEstrangeiro"] || dest.dig("enderDest", "UF") == "EX"

        if dest["IE"].to_s.upcase == "ISENTO"
          dest.delete("IE")
          dest["indIEDest"] ||= 2
        end
        dest["indIEDest"] ||= (dest["IE"] && !foreign) ? 1 : 9

        destination = dest.dig("enderDest", "UF")
        ide["idDest"] ||= if foreign
          3
        elsif destination.nil? || destination == state
          1
        else
          2
        end
        ide["indFinal"] ||= (dest["indIEDest"].to_i == 9 && ide["idDest"].to_i != 3) ? 1 : 0
      end

      def items(inf, ide, state)
        det = Array(inf["det"])
        year = issued_time(ide["dhEmi"])&.year
        context = Calculator::Context.new(origin_state: state, destination_state: inf.dig("dest", "enderDest", "UF"),
          destination: ide["idDest"], year: year, purchase_reduction: ide.dig("gCompraGov", "pRedutor"),
          purpose: ide["finNFe"], direction: ide["tpNF"], final_consumer: ide["indFinal"])
        # vItem is required with IBS/CBS (RV VB01-05).
        item_amounts = det.any? { |item| item.dig("imposto", "IBSCBS") }

        det.each_with_index do |item, index|
          item["@nItem"] ||= index + 1
          prod = (item["prod"] ||= {})
          prod["cEAN"] ||= "SEM GTIN"
          prod["cEANTrib"] ||= prod["cEAN"]
          prod["uTrib"] ||= prod["uCom"]
          prod["qTrib"] ||= prod["qCom"]
          prod["vUnTrib"] ||= prod["vUnCom"]
          prod["indTot"] ||= 1
          prod["vProd"] ||= Totals.money(Totals.number(prod["qCom"]) * Totals.number(prod["vUnCom"]))
          prod["CFOP"] = cfop(prod["CFOP"], ide) if prod["CFOP"]
        end
        # Before the taxes: freight, insurance, other expenses and the discount are part of their bases.
        Apportion.apply(det, inf.delete(Apportion::KEY) || {})
        det.each do |item|
          Calculator.call(item, context)
          item["vItem"] ||= Totals.item_amount(item, year) if item_amounts
        end
      end

      # A 3-digit CFOP ("102") gets the first digit the operation calls for ("6102").
      def cfop(value, ide)
        return value unless value.to_s.match?(/\A\d{3}\z/)

        prefix = CFOP_PREFIX.dig(ide["tpNF"].to_s, ide["idDest"].to_s)
        prefix ? "#{prefix}#{value}" : value
      end

      def payment(inf)
        pag = inf["pag"] or return
        details = Array(pag["detPag"])
        invoice_total = Totals.number(inf.dig("total", "ICMSTot", "vNF"))
        if details.size == 1 && details.first["vPag"].nil?
          details.first["vPag"] = DEFERRED_PAYMENT_KINDS.include?(details.first["tPag"].to_s) ? Totals.money(0) : Totals.money(invoice_total)
        end
        paid = Totals.sum(details) { |detail| detail["vPag"] }
        pag["vTroco"] ||= Totals.money(paid - invoice_total) if invoice_total.positive? && paid > invoice_total
      end

      def totals(inf)
        det = Array(inf["det"])
        given = inf["total"] || {}
        icms = Totals.icms_total(det).merge(given["ICMSTot"] || {})
        inf["total"] = given.merge("ICMSTot" => icms)
        selective = Totals.selective_total(det)
        inf["total"]["ISTot"] ||= selective if selective
        ibs = Totals.ibs_cbs_total(det)
        inf["total"]["IBSCBSTot"] ||= ibs if ibs
        # vNFTot is required with IBSCBSTot and is the sum of vItem (RV W60-05, W60-10).
        if inf["total"]["IBSCBSTot"] && det.all? { |item| item["vItem"] }
          inf["total"]["vNFTot"] ||= Totals.money(Totals.sum(det) { |item| item["vItem"] })
        end
        payment(inf)
      end

      # fat/vOrig defaults to the invoice total and vLiq to vOrig less the discount; a single
      # installment defaults to the net amount; installments are numbered 001, 002... in order.
      def billing(inf)
        cobr = inf["cobr"] or return
        fat = cobr["fat"]
        if fat
          fat["vOrig"] ||= inf.dig("total", "ICMSTot", "vNF")
          fat["vLiq"] ||= Totals.money(Totals.number(fat["vOrig"]) - Totals.number(fat["vDesc"]))
        end
        installments = Array(cobr["dup"])
        installments.each_with_index { |dup, index| dup["nDup"] ||= format("%03d", index + 1) }
        if installments.size == 1 && installments.first["vDup"].nil?
          installments.first["vDup"] = fat ? fat["vLiq"] : inf.dig("total", "ICMSTot", "vNF")
        end
      end

      # hashCSRT = Base64(SHA-1(CSRT + chave de acesso)) (NT 2018.005 §2.3).
      def technical_contact(inf)
        contact = inf["infRespTec"]
        return unless @csrt && contact && inf["@Id"]

        contact["hashCSRT"] ||= Base64.strict_encode64(Digest::SHA1.digest("#{@csrt}#{inf["@Id"].delete_prefix("NFe")}"))
      end

      def identify(inf, ide, emit)
        tax_id = emit["CNPJ"] || emit["CPF"]
        return unless tax_id && ide["cUF"] && ide["nNF"] && ide["dhEmi"]

        issued_at = issued_time(ide["dhEmi"])
        return unless key_parts_valid?(ide, issued_at)

        key = AccessKey.build(state: ide["cUF"], issued_at: issued_at, tax_id: tax_id,
          series: ide["serie"].to_i, number: ide["nNF"].to_i, numeric_code: ide["cNF"], model: ide["mod"].to_i,
          emission_type: ide["tpEmis"].to_i)
        ide["cDV"] = key.check_digit
        inf["@Id"] = key.id
        inf["@versao"] = "4.00"
      end

      # The key has fixed-width positions: values that don't fit are reported instead of
      # producing a malformed key.
      def key_parts_valid?(ide, issued_at)
        problems = []
        problems << "ide/dhEmi: #{ide["dhEmi"].inspect} is not a date and time (e.g. 2026-09-29T10:00:00-03:00)" unless issued_at
        problems << "ide/serie: #{ide["serie"]} is not a series (0 to 999)" unless digits?(ide["serie"], 0..999)
        problems << "ide/nNF: #{ide["nNF"]} is not an invoice number (1 to 999999999)" unless digits?(ide["nNF"], 1..999_999_999)
        problems << "ide/cNF: #{ide["cNF"]} is not an 8-digit numeric code" unless ide["cNF"].to_s.match?(/\A\d{1,8}\z/)
        problems << "ide/tpEmis: #{ide["tpEmis"]} is not an emission type (1 to 9)" unless digits?(ide["tpEmis"], 1..9)
        @issues.concat(problems)
        problems.empty?
      end

      def digits?(value, range) = value.to_s.match?(/\A\d+\z/) && range.cover?(value.to_i)

      def issued_time(value)
        return value.to_time if value.is_a?(DateTime)
        return value if value.respond_to?(:strftime)

        Time.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end
    end
  end
end
