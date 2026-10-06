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
      # IBSCBS mandatory for regime normal (RV UB12-10, NT 2025.002 v1.51), by tpAmb.
      # Homologação rejects a note without it (1115) since 01/07/2026. In production the rule
      # has no date yet ("implementação futura"; v1.51 struck out 03/08/2026), but the group is
      # mandatory by law since 01/01/2026 (the NT's schedule, LC 214/2025), so a note without
      # it is flagged all the same. The Simples Nacional and the MEI fill it from 2027 (LC
      # 214/2025, art. 348) under rules an NT is still to bring: nothing is asked of them.
      IBS_CBS_SINCE = {"2" => Time.new(2026, 7, 1, 0, 0, 0, "-03:00"), "1" => Time.new(2026, 1, 1, 0, 0, 0, "-03:00")}.freeze
      PRODUCTION = "1"
      NORMAL_REGIME = "3"
      # RV NA01-20 exception 2: in production, the DIFAL group isn't required before this.
      DIFAL_REQUIRED_SINCE = Time.new(2016, 7, 1, 0, 0, 0, "-03:00")
      DEFERRED_PAYMENT_KINDS = Resolver::DEFERRED_PAYMENT_KINDS
      MAX_STANDARD_SERIES = 889
      # Credit note types that may carry devolução CFOPs (tpNFCredito, RV I08-144).
      DEVOLUTION_CREDIT_NOTES = %w[03 04 06].freeze
      # Credit note types that, like a return, must carry devolução CFOPs (RV I08-140, I08-141).
      RETURN_CREDIT_NOTES = %w[03 06].freeze
      # Accepted on a return besides the devolução CFOPs (RV I08-140, NT 2026.009): 1949/2949
      # on any note the rule covers, 5949/6949 on the symbolic return of natural gas (Ajuste
      # SINIEF 22/21).
      RETURN_OTHER_CFOPS = %w[1949 2949].freeze
      NATURAL_GAS_RETURN_CFOPS = %w[5949 6949].freeze
      NATURAL_GAS_NCM = "27112100"
      # The only CFOPs a MEI (CRT 4) may use on a return (RV I08-141).
      MEI_RETURN_CFOPS = %w[1202 1553 2202 2553 5202 6202].freeze
      # RV NA01-20 exceptions: CFOPs that never need ICMSUFDest, the petroleum fuels (ANP
      # codes) that do, and the ICMS CSTs/CSOSNs of exempt, immune or untaxed operations.
      DIFAL_EXEMPT_CFOPS = %w[6552 6922 6929].freeze
      DIFAL_FUEL_ANP_CODES = %w[820101001 820101010 810102001 810102004 810102002 810102003 810101002 810101001
        810101003 220101003 220101004 220101002 220101001 220101005 220101006 560101001].freeze
      DIFAL_EXEMPT_ICMS = %w[40 41 103 300 400].freeze
      CFOP_TITLE_LENGTH = 60
      # xJust of a note in contingency (B29).
      CONTINGENCY_REASON_LENGTH = (15..256)

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
        check_transport_retention
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

        check_purpose_direction
        check_contingency

        presence = [2, 3, 4, 9].include?(@ide["indPres"].to_i)
        if presence && @ide["indIntermed"].nil?
          add "ide/indIntermed: required when indPres is 2, 3, 4 or 9 (rej. 434)"
        elsif !presence && !@ide["indIntermed"].nil?
          add "ide/indIntermed: only allowed when indPres is 2, 3, 4 or 9 (rej. 435)"
        end
      end

      # The emission type and what a note in contingency must say (RVs B22 and B28): since
      # when and why, and the SVC of its own state.
      def check_contingency
        emission = @ide["tpEmis"].to_s
        since, reason = @ide["dhCont"], @ide["xJust"]
        return if emission.empty?

        if emission == "1"
          add "ide/dhCont, ide/xJust: only for a note issued in contingency (rej. 556)" unless since.nil? && reason.nil?
          return
        end

        add "ide/dhCont, ide/xJust: a note in contingency says since when and why (rej. 557)" if since.nil? || reason.to_s.strip.empty?
        unless reason.nil? || CONTINGENCY_REASON_LENGTH.cover?(Formatter.sanitize(reason).length)
          add "ide/xJust: the reason for the contingency has #{CONTINGENCY_REASON_LENGTH.min} to #{CONTINGENCY_REASON_LENGTH.max} characters"
        end
        started, issued = time_of(since), issued_at
        add "ide/dhCont: the contingency can't start after the note is issued (dhEmi)" if started && issued && started > issued
        if emission == "9" && @ide["tpImp"].to_s != "6"
          add "ide/tpEmis: off-line contingency (9) is only for the DANFE Simplificado Tipo 2, tpImp 6 (rej. 711)"
        end

        state = @inf.dig("emit", "enderEmit", "UF")
        return unless %w[6 7].include?(emission) && state && States::CODES.key?(state)

        expected = States.contingency_emission_type(state)
        add "ide/tpEmis: #{state} is served by the #{States.contingency(state)}, tpEmis #{expected} (rej. 713)" unless emission == expected.to_s
      end

      # RV B25-110, B25-120: a credit note is an entry, a debit note an exit.
      def check_purpose_direction
        direction = @ide["tpNF"].to_s
        case @ide["finNFe"].to_s
        when "5"
          add "ide/tpNF: a credit note (finNFe 5) is an entry, tpNF 0 (rej. 1161)" unless direction == "0"
        when "6"
          add "ide/tpNF: a debit note (finNFe 6) is an exit, tpNF 1 (rej. 1162)" unless direction == "1"
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

        check_item_cfop(where, item)
        check_gtin("#{where}/prod/cEAN", prod["cEAN"])
        check_gtin("#{where}/prod/cEANTrib", prod["cEANTrib"])
        check_icms(where, item)
        check_item_taxes(where, item)
      end

      # The rules that consult the CFOP table (IT 2023.002). An unknown CFOP is reported
      # once (I08-04), without the rules that would need its indicators.
      def check_item_cfop(where, item)
        cfop = item.dig("prod", "CFOP")
        return if cfop.nil?

        row = check_cfop_exists(where, cfop) or return
        check_cfop(where, row)
        check_devolution_cfop(where, row)
        check_return_note_cfop(where, item, row)
        check_ibs_cbs_only_cfop(where, row)
        check_destination_group(where, item, row)
        check_fuel_group(where, item, row)
      end

      # RV I08-04: the CFOP is in the table, in force and usable in an NF-e (rej. 770).
      def check_cfop_exists(where, cfop)
        row = Tables.cfop(cfop)
        if row.nil?
          add "#{where}/prod/CFOP: #{cfop} is not in the CFOP table (IT 2023.002); look it up with " \
            "DfeRb::Nfe::Tables.cfops(matching: \"...\") (rej. 770)"
        elsif !row.nfe?
          add "#{where}/prod/CFOP: #{cfop_label(row)} can't be used in an NF-e (rej. 770)"
        elsif issued_at && !row.valid_on?(issued_at)
          add "#{where}/prod/CFOP: #{cfop_label(row)} is not in force on the issue date (rej. 770)"
        else
          return row
        end
        nil
      end

      def check_cfop(where, row)
        expected = Resolver::CFOP_PREFIX.dig((@ide["tpNF"].to_s == "0") ? "0" : "1", @ide["idDest"].to_s)
        return if expected.nil? || row.code.start_with?(expected)

        add "#{where}/prod/CFOP: #{cfop_label(row)} does not fit the operation (idDest #{@ide["idDest"]}, " \
          "#{(@ide["tpNF"].to_s == "0") ? "entry" : "exit"}): it must start with #{expected} (rej. 731-733)"
      end

      # RV I08-144: a devolução CFOP (indDevol) only on a return, a complement or a credit
      # note of type 03, 04 or 06.
      def check_devolution_cfop(where, row)
        return unless row.devolution?

        purpose = @ide["finNFe"].to_s
        return if %w[2 4].include?(purpose)
        return if purpose == "5" && DEVOLUTION_CREDIT_NOTES.include?(credit_note_type)

        add "#{where}/prod/CFOP: #{cfop_label(row)} is a devolução CFOP; a return note needs purpose :return (finNFe 4), " \
          "or :complementary for a complement of one (rej. 328)"
      end

      # RV I08-140 (as NT 2026.009 left it) and, for a MEI, I08-141: a return, or a credit
      # note of type 03 or 06, carries devolução CFOPs.
      def check_return_note_cfop(where, item, row)
        return unless return_note?

        if @inf.dig("emit", "CRT").to_s == "4" && @ide["idDest"].to_s != "3"
          return if MEI_RETURN_CFOPS.include?(row.code)

          return add "#{where}/prod/CFOP: #{cfop_label(row)} can't be used on a return issued by a MEI; " \
            "use #{MEI_RETURN_CFOPS.join(", ")} (rej. 1179)"
        end
        return if row.devolution?
        return if RETURN_OTHER_CFOPS.include?(row.code)
        return if NATURAL_GAS_RETURN_CFOPS.include?(row.code) && item.dig("prod", "NCM").to_s == NATURAL_GAS_NCM

        add "#{where}/prod/CFOP: #{cfop_label(row)} is not a devolução CFOP, which a return carries " \
          "(see DfeRb::Nfe::Tables.cfops.select(&:devolution?)) (rej. 327)"
      end

      # RV I08-191 (NT 2026.007, SVRS): an issuer without IE, taxed only by IBS/CBS, may only
      # use the CFOPs marked indExcIBSCBS, except on a return or a credit note of type 03.
      def check_ibs_cbs_only_cfop(where, row)
        emit = @inf["emit"] or return
        return unless emit["IE"].to_s.empty?
        return if row.ibs_cbs_only?
        return if @ide["finNFe"].to_s == "4" || credit_note_type == "03"

        add "#{where}/prod/CFOP: #{cfop_label(row)} can't be used by an issuer without state registration " \
          "(IBS/CBS only; see DfeRb::Nfe::Tables.cfops.select(&:ibs_cbs_only?)) (rej. 159)"
      end

      # RV NA01-20: an interstate sale to a final consumer who isn't an ICMS taxpayer carries
      # the DIFAL group, with the rule's exceptions (NT 2025.002 v1.51).
      def check_destination_group(where, item, row)
        imposto = item["imposto"] || {}
        return if imposto["ICMSUFDest"] || imposto["ISSQN"]
        return unless @ide["idDest"].to_s == "2" && @ide["indFinal"].to_s == "1" && @ide["tpNF"].to_s != "0"
        return unless @inf.dig("dest", "indIEDest").to_s == "9"
        return if %w[1 4].include?(@inf.dig("emit", "CRT").to_s)
        return if %w[2 3 5 6].include?(@ide["finNFe"].to_s) || @ide.dig("gCompraGov", "tpOperGov").to_s == "2"
        return if @ide["finNFe"].to_s == "4" && references_before_2016?(item)
        return if @ide["tpAmb"].to_s == "1" && issued_at && issued_at < DIFAL_REQUIRED_SINCE
        return if row.goods_return? || row.remittance? || DIFAL_EXEMPT_CFOPS.include?(row.code)

        name, values = Totals.icms_variant(item)
        return if name == "ICMSPart"
        return if values && DIFAL_EXEMPT_ICMS.include?((values["CST"] || values["CSOSN"]).to_s)

        fuel = item.dig("prod", "comb")
        return if fuel && !DIFAL_FUEL_ANP_CODES.include?(fuel["cProdANP"].to_s)

        delivery = @inf.dig("entrega", "UF")
        return if delivery && delivery == @inf.dig("emit", "enderEmit", "UF")

        add "#{where}/imposto/ICMSUFDest: required on #{cfop_label(row)} to a final consumer in another state " \
          "who isn't an ICMS taxpayer (DIFAL); give i.icms_destination with the destination state's rates (rej. 694)"
      end

      # RV LA01-20: a fuel CFOP (indComb 1 or 2) carries the fuel group (rej. 660).
      def check_fuel_group(where, item, row)
        return unless row.fuel? && item.dig("prod", "comb").nil?

        add "#{where}/prod/comb: required on #{cfop_label(row)}, a fuel CFOP (rej. 660)"
      end

      # RV X16-10: the retained transport ICMS takes a transport CFOP (indTransp, rej. 722).
      def check_transport_retention
        cfop = @inf.dig("transp", "retTransp", "CFOP") or return
        row = Tables.cfop(cfop)
        return if row&.transport?

        add "transp/retTransp/CFOP: #{row ? cfop_label(row) : cfop} is not a transport CFOP " \
          "(see DfeRb::Nfe::Tables.cfops.select(&:transport?)) (rej. 722)"
      end

      def return_note?
        @ide["finNFe"].to_s == "4" || (@ide["finNFe"].to_s == "5" && RETURN_CREDIT_NOTES.include?(credit_note_type))
      end

      def credit_note_type = @ide["tpNFCredito"].to_s.rjust(2, "0")

      # Whether the note references an NF-e issued before 2016 (the key's year digits,
      # NA01-20), in ide/NFref or in the item's DFeReferenciado, where a return references
      # its note (VC02-14).
      def references_before_2016?(item)
        keys = [@ide["NFref"]].flatten.compact.map { |reference| reference.is_a?(Hash) ? reference["refNFe"].to_s : "" }
        keys << item.dig("DFeReferenciado", "chaveAcesso").to_s
        keys.any? { |key| key.match?(/\A\d{4}/) && key[2, 2].to_i < 16 }
      end

      # "6916 (Retorno de mercadoria ou bem recebido para conserto ou…)"
      def cfop_label(row)
        title = row.title.to_s.delete_suffix(".")
        if title.length > CFOP_TITLE_LENGTH
          cut = title[0, CFOP_TITLE_LENGTH + 1].sub(/\s+\S*\z/, "").sub(/(?:[\s,;]+(?:ou|e|de|da|do|para|com|a|o|em))*[\s,;]*\z/, "")
          title = "#{cut}…"
        end
        "#{row.code} (#{title})"
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
        check_ibs_cbs_item(where, imposto["IBSCBS"])
        return unless item["vItem"] && issued_at

        check_amount("#{where}/vItem", item["vItem"], Totals.item_amount(item, issued_at.year),
          "the sum of the values that make it up", 1105)
      end

      # Per sphere: its tags and the rejections for the amount, the effective rate, the rate
      # under regular taxation, and gDif missing where the CST requires it or given where it
      # doesn't allow it.
      IBS_CBS_SPHERES = [
        ["gIBSUF", "pIBSUF", "vIBSUF", {amount: 1041, effective: 1035, rate: 1026, deferral: 1030, no_deferral: 1029}],
        ["gIBSMun", "pIBSMun", "vIBSMun", {amount: 1052, effective: 1035, rate: 1036, deferral: 1044, no_deferral: 1083}],
        ["gCBS", "pCBS", "vCBS", {amount: 1069, effective: 1064, rate: 1037, deferral: 1061, no_deferral: 1090}]
      ].freeze

      def check_ibs_cbs_item(where, ibscbs)
        group = ibscbs&.dig("gIBSCBS") or return

        klass = Tables.classification(ibscbs["cClassTrib"])
        check_regular_taxation(where, group, klass)
        purchase = @ide.dig("gCompraGov", "pRedutor")
        IBS_CBS_SPHERES.each do |tag, rate_tag, amount_tag, codes|
          sphere = group[tag] or next
          path = "#{where}/imposto/IBSCBS/gIBSCBS/#{tag}"
          check_deferral(path, sphere, klass, codes)
          if klass&.regular_taxation? && @ide["finNFe"].to_s == "1" && !Totals.number(sphere[rate_tag]).zero?
            add "#{path}/#{rate_tag}: must be 0 for cClassTrib #{klass.code}, taxed in gTribRegular (rej. #{codes[:rate]})"
          end
          red = sphere["gRed"]
          if red && !red["pAliqEfet"].nil? && !sphere[rate_tag].nil? && !red["pRedAliq"].nil?
            expected = Calculator.effective_rate(sphere[rate_tag], red["pRedAliq"], purchase)
            if (Totals.number(red["pAliqEfet"]) - expected).abs > BigDecimal("0.0001")
              add "#{path}/gRed/pAliqEfet: #{red["pAliqEfet"]} differs from the rate less the reduction (#{expected.to_s("F")}) " \
                "(rej. #{codes[:effective]})"
            end
          end
          check_amount("#{path}/#{amount_tag}", sphere[amount_tag], Calculator.expected_ibs_cbs(group, sphere, rate_tag),
            "base x rate - deferral - returned tax", codes[:amount])
        end
      end

      # gTribRegular is required exactly when the classification calls for it (RV UB68-10, UB68-11).
      def check_regular_taxation(where, group, klass)
        return unless klass

        path = "#{where}/imposto/IBSCBS/gIBSCBS/gTribRegular"
        if klass.regular_taxation? && group["gTribRegular"].nil?
          add "#{path}: required for cClassTrib #{klass.code} (rej. 1065)"
        elsif !klass.regular_taxation? && group["gTribRegular"]
          add "#{path}: not allowed for cClassTrib #{klass.code} (rej. 1114)"
        end
      end

      # gDif is required exactly when the CST calls for deferral (RV UB22, UB40, UB59).
      def check_deferral(path, sphere, klass, codes)
        return unless klass

        if klass.deferral? && sphere["gDif"].nil?
          add "#{path}/gDif: required for CST #{klass.cst} (rej. #{codes[:deferral]})"
        elsif !klass.deferral? && sphere["gDif"]
          add "#{path}/gDif: not allowed for CST #{klass.cst} (rej. #{codes[:no_deferral]})"
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

        details.each_with_index { |detail, index| check_payment_kind("pag/detPag[#{index + 1}]/tPag", detail["tPag"].to_s) }
        deferred = details.select { |detail| DEFERRED_PAYMENT_KINDS.include?(detail["tPag"].to_s) }
        unless deferred.all? { |detail| Totals.number(detail["vPag"]).zero? }
          add "pag/detPag: with tPag 90 (no payment) or 91 (paid later) vPag must be 0.00 (rej. 904)"
        end
        check_payment_total(details) unless deferred.any?
      end

      # The tPag is in the payment methods table and accepted on the issue date (IT 2024.002).
      def check_payment_kind(path, kind)
        return if kind.empty?

        method = Tables.payment_method(kind)
        if method.nil?
          add "#{path}: #{kind} is not a payment method (see DfeRb::Nfe::Tables.payment_methods)"
        elsif issued_at && !method.valid_on?(issued_at)
          add "#{path}: #{kind} (#{method.title}) is only accepted from #{Date.iso8601(method.valid_from).strftime("%d/%m/%Y")}"
        end
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

      # Every item of a regime normal issuer carries IBS/CBS (RV UB12-10): a rejection in
      # homologação, the law alone in production. Devolução (finNFe 4) is exempt; so is a
      # complementar note referencing one issued before 2027, which can't be told from here,
      # so finNFe 2 is left to SEFAZ.
      def check_ibs_cbs
        return if %w[2 4].include?(@ide["finNFe"].to_s)
        return unless @inf.dig("emit", "CRT").to_s == NORMAL_REGIME

        since = IBS_CBS_SINCE[@ide["tpAmb"].to_s]
        return unless since && issued_at && issued_at >= since

        ground = (@ide["tpAmb"].to_s == PRODUCTION) ? "LC 214/2025; not a rejection in production yet" : "rej. 1115"
        Array(@inf["det"]).each_with_index do |item, index|
          next if item.dig("imposto", "IBSCBS") || item.dig("prod", "comb")

          add "det[#{index + 1}]/imposto/IBSCBS: mandatory for regime normal since #{since.strftime("%d/%m/%Y")} (#{ground})"
        end
      end

      # RV 7ZD09-10 (rej. 978), checkable only when the CSRT is known.
      def check_technical_contact
        given = @inf.dig("infRespTec", "hashCSRT")
        return unless @csrt && given && @inf["@Id"]

        expected = Base64.strict_encode64(Digest::SHA1.digest("#{@csrt}#{@inf["@Id"].delete_prefix("NFe")}"))
        add "infRespTec/hashCSRT: does not match the CSRT and the access key (rej. 978)" unless given == expected
      end

      # dhEmi as a Time in its own offset, whose year is the issue year the Resolver used.
      def issued_at = time_of(@ide["dhEmi"])

      def time_of(value)
        return value.to_time if value.respond_to?(:to_time) && !value.is_a?(String)

        Time.iso8601(value.to_s) if value
      rescue ArgumentError
        nil
      end

      # Compares a given amount with the expected one rounded as the XML would show it; with
      # no expected value (one the gem can't compute) there is nothing to compare.
      def check_amount(path, given, expected, description, rejection = nil)
        return if given.nil? || expected.nil?

        difference = (Totals.number(given) - Totals.money(expected)).abs
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
