require "bigdecimal"
require "date"
require "time"

module DfeRb
  module Nfe
    # Completes an invoice: fills the defaults a developer shouldn't have to spell out and
    # derives what follows from other fields (access key, destination indicator, totals...).
    # Anything the developer set explicitly is kept.
    class Resolver
      HOMOLOGACAO_RECIPIENT_NAME = "NF-E EMITIDA EM AMBIENTE DE HOMOLOGACAO - SEM VALOR FISCAL"

      # Values that must stay the same across resolves of one invoice (a retry must never
      # produce another cNF or emission time). Held by the Invoice.
      Memo = Struct.new(:numeric_code, :issued_at)

      # Problems that stopped a field from being derived (the access key needs a valid
      # emission date, series and number), as validation messages.
      attr_reader :issues

      def initialize(environment:, memo:, clock: Time)
        @environment = Environment.normalize(environment)
        @memo = memo
        @clock = clock
        @issues = []
      end

      # `infNFe` (tag-keyed Hash) => a resolved copy.
      def call(infnfe)
        @issues = []
        inf = Marshal.load(Marshal.dump(infnfe))
        normalize(inf, Schema.nfe.find("infNFe"))
        ide = (inf["ide"] ||= {})
        emit = inf["emit"] || {}
        state = emit.dig("enderEmit", "UF")

        defaults(ide, emit, state)
        recipient(inf, ide, state)
        items(inf)
        inf["transp"] ||= {}
        inf["transp"]["modFrete"] = 9 if inf["transp"]["modFrete"].nil?
        totals(inf)
        identify(inf, ide, emit)
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

      def defaults(ide, emit, state)
        ide["cUF"] ||= States.code(state) if state
        ide["mod"] ||= 55
        ide["serie"] ||= 1
        ide["tpNF"] ||= 1
        ide["cMunFG"] ||= emit.dig("enderEmit", "cMun")
        ide["tpImp"] ||= 1
        ide["tpEmis"] ||= 1
        ide["tpAmb"] ||= Environment.code(@environment)
        ide["finNFe"] ||= 1
        ide["indPres"] ||= 1
        ide["procEmi"] ||= 0
        ide["verProc"] ||= "dfe_rb #{DfeRb::VERSION}"
        ide["indIntermed"] ||= 0 if [2, 3, 4, 9].include?(ide["indPres"].to_i)
        # A copy, so nothing done to the tree can change the memoized time.
        ide["dhEmi"] ||= (@memo.issued_at ||= now_in(state)).dup
        ide["dhEmi"] = ide["dhEmi"].to_time if ide["dhEmi"].is_a?(DateTime)
        ide["cNF"] ||= (@memo.numeric_code ||= AccessKey.generate_numeric_code(number: ide["nNF"]))
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

      def items(inf)
        Array(inf["det"]).each_with_index do |item, index|
          item["@nItem"] ||= index + 1
          prod = (item["prod"] ||= {})
          prod["cEAN"] ||= "SEM GTIN"
          prod["cEANTrib"] ||= prod["cEAN"]
          prod["uTrib"] ||= prod["uCom"]
          prod["qTrib"] ||= prod["qCom"]
          prod["vUnTrib"] ||= prod["vUnCom"]
          prod["indTot"] ||= 1
          prod["vProd"] ||= Totals.money(Totals.number(prod["qCom"]) * Totals.number(prod["vUnCom"]))
          derive_item_taxes(item)
        end
      end

      def derive_item_taxes(item)
        group = item.dig("imposto", "IBSCBS", "gIBSCBS") or return

        if group["vIBS"].nil? && (group["gIBSUF"] || group["gIBSMun"])
          group["vIBS"] = Totals.money(Totals.number(group.dig("gIBSUF", "vIBSUF")) + Totals.number(group.dig("gIBSMun", "vIBSMun")))
        end
      end

      def payment(inf)
        pag = inf["pag"] or return
        details = Array(pag["detPag"])
        paid = Totals.sum(details) { |detail| detail["vPag"] }
        invoice_total = Totals.number(inf.dig("total", "ICMSTot", "vNF"))
        pag["vTroco"] ||= Totals.money(paid - invoice_total) if invoice_total.positive? && paid > invoice_total
      end

      def totals(inf)
        det = Array(inf["det"])
        given = inf["total"] || {}
        icms = Totals.icms_total(det).merge(given["ICMSTot"] || {})
        inf["total"] = given.merge("ICMSTot" => icms)
        ibs = Totals.ibs_cbs_total(det)
        inf["total"]["IBSCBSTot"] ||= ibs if ibs
        payment(inf)
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
