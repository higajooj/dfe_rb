require "base64"
require "bigdecimal"
require "digest"
require "time"

module DfeRb
  module Nfe
    # Business rules SEFAZ enforces that the schema can't express, checked locally so a mistake
    # costs nothing instead of a rejection. Only unambiguous rules are here (Anexo I RVs and
    # the NTs that amend them); rules that depend on state tables stay with SEFAZ.
    class Validator
      TOLERANCE = BigDecimal("0.01")
      # IBSCBS mandatory for regime normal (RV UB12-10, NT 2025.002 v1.51), by tpAmb: in
      # homologação since 01/07/2026, in production not yet ("implementação futura").
      IBS_CBS_MANDATORY_SINCE = {"2" => Time.new(2026, 7, 1, 0, 0, 0, "-03:00"), "1" => nil}.freeze
      DEFERRED_PAYMENT_KINDS = Resolver::DEFERRED_PAYMENT_KINDS
      MAX_STANDARD_SERIES = 889

      # csrt: the CSRT the invoice was built with, to check hashCSRT against.
      def initialize(infnfe, csrt: nil)
        @inf = infnfe
        @ide = infnfe["ide"] || {}
        @csrt = csrt
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
        check_technical_contact
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
        check_item_taxes(where, item)
      end

      def check_cfop(where, cfop)
        return if cfop.nil?

        expected = Resolver::CFOP_PREFIX.dig((@ide["tpNF"].to_s == "0") ? "0" : "1", @ide["idDest"].to_s)
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
        return unless name && @ide["finNFe"].to_s == "1"

        path = "#{where}/imposto/ICMS/#{name}"
        if %w[ICMS00 ICMS10 ICMS20 ICMS70].include?(name)
          check_amount("#{path}/vICMS", values["vICMS"], Calculator.expected_icms(name, values), "base x rate", 528)
        end
        check_amount("#{path}/vFCP", values["vFCP"], Calculator.expected_fcp(name, values), "base x FCP rate", 860)
      end

      # Values SEFAZ recomputes from the item's own bases and rates.
      def check_item_taxes(where, item)
        imposto = item["imposto"] || {}
        if (destination = imposto["ICMSUFDest"])
          path = "#{where}/imposto/ICMSUFDest"
          check_amount("#{path}/vFCPUFDest", destination["vFCPUFDest"], Calculator.expected_destination_fcp(destination),
            "base x FCP rate", 793)
          shares = Calculator.expected_destination_shares(destination)
          if shares
            check_amount("#{path}/vICMSUFDest", destination["vICMSUFDest"], shares.first,
              "base x (destination rate - interstate rate) x partition", 815)
            remainder = shares.sum - Totals.number(destination["vICMSUFDest"] || shares.first)
            check_amount("#{path}/vICMSUFRemet", destination["vICMSUFRemet"], remainder, "the rest of the rate difference", 816)
          end
        end
        if (selective = imposto["IS"])
          check_amount("#{where}/imposto/IS/vIS", selective["vIS"], Calculator.expected_selective(selective), "base x rate", 1019)
        end
        check_ibs_cbs_item(where, imposto.dig("IBSCBS", "gIBSCBS"))
        return unless item["vItem"] && issued_at

        check_amount("#{where}/vItem", item["vItem"], Totals.item_amount(item, issued_at.year),
          "the sum of the values that make it up", 1105)
      end

      IBS_CBS_SPHERES = [["gIBSUF", "pIBSUF", "vIBSUF", 1041, 1035], ["gIBSMun", "pIBSMun", "vIBSMun", 1052, 1035],
        ["gCBS", "pCBS", "vCBS", 1069, 1064]].freeze

      def check_ibs_cbs_item(where, group)
        return unless group

        purchase = @ide.dig("gCompraGov", "pRedutor")
        IBS_CBS_SPHERES.each do |tag, rate_tag, amount_tag, rejection, rate_rejection|
          sphere = group[tag] or next
          path = "#{where}/imposto/IBSCBS/gIBSCBS/#{tag}"
          red = sphere["gRed"]
          if red && !red["pAliqEfet"].nil? && !sphere[rate_tag].nil? && !red["pRedAliq"].nil?
            expected = Calculator.effective_rate(sphere[rate_tag], red["pRedAliq"], purchase)
            if (Totals.number(red["pAliqEfet"]) - expected).abs > BigDecimal("0.0001")
              add "#{path}/gRed/pAliqEfet: #{red["pAliqEfet"]} differs from the rate less the reduction (#{expected.to_s("F")}) " \
                "(rej. #{rate_rejection})"
            end
          end
          check_amount("#{path}/#{amount_tag}", sphere[amount_tag], Calculator.expected_ibs_cbs(group, sphere, rate_tag),
            "base x rate - deferral - returned tax", rejection)
        end
      end

      def check_totals
        det = Array(@inf["det"])
        total = @inf["total"] || {}
        if total["vNFTot"] && det.all? { |item| item["vItem"] }
          check_amount("total/vNFTot", total["vNFTot"], Totals.sum(det) { |item| item["vItem"] }, "the sum of the items' vItem", 1094)
        end
        given = total["ICMSTot"] or return
        expected = Totals.icms_total(det)
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

        deferred = details.select { |detail| DEFERRED_PAYMENT_KINDS.include?(detail["tPag"].to_s) }
        unless deferred.all? { |detail| Totals.number(detail["vPag"]).zero? }
          add "pag/detPag: with tPag 90 (no payment) or 91 (paid later) vPag must be 0.00 (rej. 904)"
        end
        check_payment_total(details) unless deferred.any?
      end

      # RV YA03-10 is only active for NFC-e ("implementação futura para modelo 55").
      def check_payment_total(details)
        return unless @ide["mod"].to_s == "65"
        return if %w[3 4].include?(@ide["finNFe"].to_s)

        paid = Totals.sum(details) { |detail| detail["vPag"] }
        total = Totals.number(@inf.dig("total", "ICMSTot", "vNF"))
        return unless paid < total - TOLERANCE

        add "pag: the payments (#{amount(paid)}) are less than the invoice total (#{amount(total)}) (rej. 865)"
      end

      def check_billing
        cobr = @inf["cobr"] or return
        installments = Array(cobr["dup"])
        net = cobr.dig("fat", "vLiq")
        return if installments.empty? || net.nil?

        check_amount("cobr/dup", Totals.sum(installments) { |dup| dup["vDup"] }, net, "the invoice net amount (fat/vLiq)")
      end

      # Regime normal must carry IBS/CBS where the RTC is in force (RV UB12-10). Devolução
      # (finNFe 4) is exempt; so is a complementar note referencing one issued before 2027,
      # which can't be told from here, so finNFe 2 is left to SEFAZ.
      def check_ibs_cbs
        return unless @inf.dig("emit", "CRT").to_s == "3"
        return if %w[2 4].include?(@ide["finNFe"].to_s)

        since = IBS_CBS_MANDATORY_SINCE[@ide["tpAmb"].to_s]
        return unless since && issued_at && issued_at >= since

        Array(@inf["det"]).each_with_index do |item, index|
          next if item.dig("imposto", "IBSCBS") || item.dig("prod", "comb")

          add "det[#{index + 1}]/imposto/IBSCBS: mandatory for regime normal in homologacao since " \
            "#{since.strftime("%d/%m/%Y")} (rej. 1115)"
        end
      end

      # RV 7ZD09-10 (rej. 978), checkable only when the CSRT is known.
      def check_technical_contact
        given = @inf.dig("infRespTec", "hashCSRT")
        return unless @csrt && given && @inf["@Id"]

        expected = Base64.strict_encode64(Digest::SHA1.digest("#{@csrt}#{@inf["@Id"].delete_prefix("NFe")}"))
        add "infRespTec/hashCSRT: does not match the CSRT and the access key (rej. 978)" unless given == expected
      end

      # dhEmi as a Time, without touching the value in the tree (Time#utc would change it in
      # place, and with it the invoice's memoized issue time).
      def issued_at
        value = @ide["dhEmi"]
        return value.to_time.getutc if value.respond_to?(:to_time) && !value.is_a?(String)

        Time.iso8601(value.to_s).getutc if value
      rescue ArgumentError
        nil
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
