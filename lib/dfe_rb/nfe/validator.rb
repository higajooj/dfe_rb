require "bigdecimal"
require "time"

module DfeRb
  module Nfe
    # Business rules SEFAZ enforces that the schema can't express, checked locally so a mistake
    # costs nothing instead of a rejection. Only unambiguous rules are here (Anexo I RVs and
    # the NTs that amend them); rules that depend on state tables stay with SEFAZ.
    class Validator
      TOLERANCE = BigDecimal("0.01")
      IBS_CBS_MANDATORY_SINCE = Time.utc(2026, 8, 3)
      MAX_STANDARD_SERIES = 889

      def initialize(infnfe)
        @inf = infnfe
        @ide = infnfe["ide"] || {}
        @issues = []
      end

      # Messages for each rule the invoice breaks.
      def issues
        check_parties
        check_identification
        Array(@inf["det"]).each_with_index { |item, index| check_item(item, index + 1) }
        check_totals
        check_payment
        check_billing
        check_ibs_cbs
        @issues
      end

      private

      def check_parties
        emit = @inf["emit"]
        check_tax_id("emit", emit) if emit
        %w[dest retirada entrega].each { |tag| check_tax_id(tag, @inf[tag]) if @inf[tag] }
        Array(@inf["autXML"]).each { |entry| check_tax_id("autXML", entry) }

        dest = @inf["dest"]
        if dest.nil?
          add "dest: the recipient is mandatory in NF-e modelo 55 (rej. 719)"
        else
          add "dest/xNome: the recipient name is mandatory (rej. 724)" if dest["xNome"].to_s.empty?
          add "dest/enderDest: the recipient address is mandatory (rej. 726)" if dest["enderDest"].nil?
          if dest["idEstrangeiro"].nil? && dest["CNPJ"].nil? && dest["CPF"].nil?
            add "dest: give the recipient's CNPJ, CPF or foreign id"
          end
        end

        state = emit&.dig("enderEmit", "UF")
        return unless state && States::CODES.key?(state)

        city = emit.dig("enderEmit", "cMun").to_s
        add "emit/enderEmit/cMun: city #{city} does not belong to #{state} (rej. 273)" unless city.start_with?(States.code(state))
        fg = @ide["cMunFG"].to_s
        add "ide/cMunFG: city #{fg} does not belong to #{state} (rej. 271)" unless fg.empty? || fg.start_with?(States.code(state))
      end

      def check_tax_id(path, party)
        %w[CNPJ CPF].each do |tag|
          value = party[tag].to_s
          next if value.empty?

          valid = (tag == "CNPJ") ? TaxId.valid_cnpj?(value) : TaxId.valid_cpf?(value)
          add "#{path}/#{tag}: #{value} is not a valid #{tag} (check digits)" unless valid
        end
      end

      def check_identification
        series = @ide["serie"].to_i
        if @ide["procEmi"].to_i.zero? && series > MAX_STANDARD_SERIES
          add "ide/serie: #{series} is reserved (own software uses series 0 to #{MAX_STANDARD_SERIES}, rej. 244)"
        end
        add "ide/nNF: the invoice number is required" if @ide["nNF"].nil?
        add "ide/natOp: the nature of the operation is required" if @ide["natOp"].to_s.empty?

        dest = @inf["dest"] || {}
        if dest["indIEDest"].to_s == "9" && @ide["tpNF"].to_s == "1" && @ide["idDest"].to_s != "3" && @ide["indFinal"].to_s != "1"
          add "ide/indFinal: must be 1 (final consumer) when the recipient is not an ICMS taxpayer (rej. 696)"
        end

        presence = [2, 3, 4, 9].include?(@ide["indPres"].to_i)
        if presence && @ide["indIntermed"].nil?
          add "ide/indIntermed: required when indPres is 2, 3, 4 or 9 (rej. 434)"
        elsif !presence && !@ide["indIntermed"].nil?
          add "ide/indIntermed: only allowed when indPres is 2, 3, 4 or 9 (rej. 435)"
        end
      end

      def check_item(item, number)
        prod = item["prod"] || {}
        where = "det[#{number}]"

        check_amount("#{where}/prod/vProd", prod["vProd"], Totals.number(prod["qCom"]) * Totals.number(prod["vUnCom"]),
          "quantity x unit price", 629)
        if @ide["finNFe"].to_s == "1"
          check_amount("#{where}/prod/vProd", prod["vProd"], Totals.number(prod["qTrib"]) * Totals.number(prod["vUnTrib"]),
            "taxable quantity x taxable unit price", 630)
        end
        if Totals.number(prod["vDesc"]) > Totals.number(prod["vProd"])
          add "#{where}/prod/vDesc: the discount exceeds the item value (rej. 483)"
        end

        check_cfop(where, prod["CFOP"])
        check_gtin("#{where}/prod/cEAN", prod["cEAN"])
        check_gtin("#{where}/prod/cEANTrib", prod["cEANTrib"])
        check_icms(where, item)
      end

      def check_cfop(where, cfop)
        return if cfop.nil?

        expected = if @ide["tpNF"].to_s == "0"
          {"1" => "1", "2" => "2", "3" => "3"}
        else
          {"1" => "5", "2" => "6", "3" => "7"}
        end[@ide["idDest"].to_s]
        return if expected.nil? || cfop.to_s.start_with?(expected)

        add "#{where}/prod/CFOP: #{cfop} does not fit the operation (idDest #{@ide["idDest"]}, " \
          "#{(@ide["tpNF"].to_s == "0") ? "entry" : "exit"}): it must start with #{expected} (rej. 731-733)"
      end

      def check_gtin(path, value)
        code = value.to_s
        return if code.empty? || code == "SEM GTIN"

        digits = code.each_char.map(&:to_i)
        unless [8, 12, 13, 14].include?(digits.size) && code.match?(/\A\d+\z/)
          return add "#{path}: #{code} is not a GTIN (8, 12, 13 or 14 digits) or SEM GTIN"
        end

        body = digits[0...-1].reverse.each_with_index.sum { |digit, index| digit * (index.even? ? 3 : 1) }
        add "#{path}: #{code} has a wrong GTIN check digit (rej. 611)" unless digits.last == (10 - body % 10) % 10
      end

      def check_icms(where, item)
        name, values = Totals.icms_variant(item)
        return unless name && %w[ICMS00 ICMS10 ICMS20 ICMS70].include?(name)
        return unless @ide["finNFe"].to_s == "1"

        expected = Totals.number(values["vBC"]) * Totals.number(values["pICMS"]) / 100
        check_amount("#{where}/imposto/ICMS/#{name}/vICMS", values["vICMS"], expected, "base x rate", 528)
      end

      def check_totals
        given = @inf.dig("total", "ICMSTot") or return
        expected = Totals.icms_total(Array(@inf["det"]))
        expected.each do |tag, value|
          next if given[tag].nil?

          check_amount("total/ICMSTot/#{tag}", given[tag], value, "the sum of the items")
        end
      end

      def check_payment
        details = Array(@inf.dig("pag", "detPag"))
        if details.empty?
          return add "pag/detPag: at least one payment is required (use kind: :no_payment for none)"
        end

        paid = Totals.sum(details) { |detail| detail["vPag"] }
        total = Totals.number(@inf.dig("total", "ICMSTot", "vNF"))
        no_payment = details.all? { |detail| detail["tPag"].to_s == "90" }
        adjustment = %w[3 4].include?(@ide["finNFe"].to_s)

        if no_payment
          add "pag/detPag: with tPag 90 (no payment) vPag must be 0.00 (rej. 871)" unless paid.zero?
        elsif !adjustment && paid < total - TOLERANCE
          add "pag: the payments (#{amount(paid)}) are less than the invoice total (#{amount(total)}) (rej. 865)"
        end
      end

      def check_billing
        cobr = @inf["cobr"] or return
        installments = Array(cobr["dup"])
        net = cobr.dig("fat", "vLiq")
        return if installments.empty? || net.nil?

        check_amount("cobr/dup", Totals.sum(installments) { |dup| dup["vDup"] }, net, "the invoice net amount (fat/vLiq)")
      end

      # Regime normal must carry IBS/CBS on ordinary notes since the RTC took effect.
      def check_ibs_cbs
        return unless @inf.dig("emit", "CRT").to_s == "3"
        return unless %w[1 3].include?(@ide["finNFe"].to_s)
        return unless issued_at && issued_at >= IBS_CBS_MANDATORY_SINCE

        Array(@inf["det"]).each_with_index do |item, index|
          next if item.dig("imposto", "IBSCBS") || item.dig("prod", "comb")

          add "det[#{index + 1}]/imposto/IBSCBS: mandatory for regime normal since 03/08/2026 (rej. 1115)"
        end
      end

      def issued_at
        value = @ide["dhEmi"]
        value.respond_to?(:utc) ? value.utc : (Time.iso8601(value.to_s).utc if value)
      end

      def check_amount(path, given, expected, description, rejection = nil)
        return if given.nil?

        difference = (Totals.number(given) - Totals.number(expected)).abs
        return if difference <= TOLERANCE

        add "#{path}: #{amount(given)} differs from #{description} (#{amount(expected)})#{" (rej. #{rejection})" if rejection}"
      end

      def amount(value) = format("%.2f", Totals.number(value))

      def add(message)
        @issues << message unless @issues.include?(message)
      end
    end
  end
end
