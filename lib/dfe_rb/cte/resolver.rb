require "base64"
require "bigdecimal"
require "digest"
require "time"

module DfeRb
  module Cte
    class Resolver
      FLAGS = %w[indGlobalizado indAlteraToma indDoacao].freeze
      HOMOLOGACAO_NAME = "CTE EMITIDO EM AMBIENTE DE HOMOLOGACAO - SEM VALOR FISCAL"
      EXTERIOR = "EX"
      EXTERIOR_CITY = "9999999"
      MEASURE_DEFAULTS = {
        "00" => "CUBAGEM", "01" => "PESO BRUTO", "02" => "PESO BRUTO",
        "03" => "UNIDADE", "04" => "LITRAGEM", "05" => "MMBTU"
      }.freeze
      PARTY_ADDRESSES = {
        "emit" => "enderEmit", "rem" => "enderReme", "exped" => "enderExped",
        "receb" => "enderReceb", "dest" => "enderDest"
      }.freeze
      TAKER_PARTIES = {"0" => "rem", "1" => "exped", "2" => "receb", "3" => "dest"}.freeze
      NFF = "3"

      Memo = Struct.new(:numeric_code, :issued_at)

      attr_reader :issues

      def initialize(environment:, memo:, clock: Time, csrt: nil)
        @environment = Environment.normalize(environment)
        @memo = memo
        @clock = clock
        @csrt = csrt
        @issues = []
      end

      def call(infcte)
        @issues = []
        inf = Marshal.load(Marshal.dump(infcte))
        normalize(inf, Schema.cte.find("infCte"))
        ide = (inf["ide"] ||= {})
        emit = inf["emit"] || {}

        complete_addresses(inf, ide)
        state = emit.dig("enderEmit", "UF")
        complete_locations(inf, ide, emit)
        complete_modal(inf, ide)
        complete_defaults(inf, ide, state)
        complete_homologacao(inf, ide)
        complete_taker_indicator(inf, ide)
        complete_service_value(inf)
        complete_icms(inf)
        complete_ibs_cbs(inf, ide)
        complete_cargo(inf)
        complete_billing(inf)
        complete_payment_links(inf)
        identify(inf, ide, emit)
        technical_contact(inf)
        inf
      end

      private

      def normalize(data, element)
        element.each_element do |child|
          next unless data.key?(child.tag)

          value = data[child.tag]
          if child.leaf? && child.type
            next data.delete(child.tag) if FLAGS.include?(child.tag) && value.to_s == "0"

            data[child.tag] = value.is_a?(Array) ? value.map { |item| Formatter.forgive(item, child) } : Formatter.forgive(value, child)
          else
            (value.is_a?(Array) ? value : [value]).each { |entry| normalize(entry, child) if entry.is_a?(Hash) }
          end
        end
      end

      def complete_addresses(inf, ide)
        PARTY_ADDRESSES.each do |party_tag, addr_tag|
          address(inf.dig(party_tag, addr_tag))
        end
        address(ide.dig("toma4", "enderToma"))
      end

      def address(addr)
        return unless addr.is_a?(Hash)

        code = addr["cMun"].to_s
        addr["UF"] ||= state_of(code) if code.match?(/\A\d{7}\z/)
        addr["xMun"] ||= (code == EXTERIOR_CITY) ? "EXTERIOR" : Cities.name(code) unless code.empty?
        addr["cMun"] ||= (addr["UF"] == EXTERIOR) ? EXTERIOR_CITY : Cities.code(addr["xMun"], addr["UF"]) if addr["xMun"] && addr["UF"]
      end

      def complete_locations(inf, ide, emit)
        emit_addr = emit["enderEmit"] || {}
        fill_location(ide, "Env", emit_addr)
        fill_location(ide, "Ini", inf.dig("rem", "enderReme") || emit_addr)
        fill_location(ide, "Fim", inf.dig("dest", "enderDest"))
      end

      def fill_location(ide, suffix, fallback)
        code_key, name_key, state_key = "cMun#{suffix}", "xMun#{suffix}", "UF#{suffix}"
        if ide[code_key].nil? && ide[name_key].nil? && ide[state_key].nil? && fallback.is_a?(Hash)
          ide[code_key] = fallback["cMun"] if fallback["cMun"]
          ide[name_key] = fallback["xMun"] if fallback["xMun"]
          ide[state_key] = fallback["UF"] if fallback["UF"]
        end

        code = ide[code_key].to_s
        ide[state_key] ||= state_of(code) if code.match?(/\A\d{7}\z/)
        ide[name_key] ||= (code == EXTERIOR_CITY) ? "EXTERIOR" : Cities.name(code) unless code.empty?
        ide[code_key] ||= (ide[state_key] == EXTERIOR) ? EXTERIOR_CITY : Cities.code(ide[name_key], ide[state_key]) if ide[name_key] && ide[state_key]
      end

      def state_of(city_code)
        code = city_code.to_s
        return unless code.match?(/\A\d{7}\z/)

        code.start_with?("99") ? EXTERIOR : DfeRb::States::CODES.key(code[0, 2].to_i)
      end

      def complete_modal(inf, ide)
        group = inf.dig("infCTeNorm", "infModal") or return
        given = Schema::MODALS.keys.select { |tag| group[tag] }
        return unless given.size == 1

        ide["modal"] ||= Schema::MODALS.fetch(given.first).last
        group["@versaoModal"] ||= Schema::VERSION
      end

      def complete_defaults(inf, ide, state)
        ide["cUF"] ||= DfeRb::States.code(state) if state && DfeRb::States::CODES.key?(state)
        ide["tpAmb"] ||= Environment.code(@environment)
        ide["mod"] ||= AccessKey::MODEL
        if ide["tpEmis"] == :svc
          ide["tpEmis"] = (state && DfeRb::States::CODES.key?(state)) ? States.contingency_emission_type(state) : 7
        end
        ide["tpEmis"] ||= 1
        emit = inf["emit"] || {}
        default_series = (emit["CPF"] && emit["CNPJ"].nil? && ide["tpEmis"].to_s != NFF) ? AccessKey::PERSON_SERIES.min : 1
        ide["serie"] ||= default_series
        ide["tpImp"] ||= 1
        ide["tpCTe"] ||= derive_cte_type(inf)
        ide["procEmi"] ||= 0
        ide["verProc"] ||= "dfe_rb #{DfeRb::VERSION}"
        ide["tpServ"] ||= 0
        ide["retira"] ||= 1
        ide["dhEmi"] ||= (@memo.issued_at ||= now_in(state)).dup
        ide["dhEmi"] = ide["dhEmi"].to_time if ide["dhEmi"].is_a?(DateTime)
        ide["dhCont"] = ide["dhCont"].to_time if ide["dhCont"].is_a?(DateTime)
        ide["cCT"] ||= (@memo.numeric_code ||= AccessKey.generate_numeric_code(number: ide["nCT"]))
      end

      def derive_cte_type(inf)
        return 1 if Array(inf["infCteComp"]).any?
        return 3 if inf.dig("infCTeNorm", "infCteSub")

        0
      end

      def now_in(state)
        (state && DfeRb::States::CODES.key?(state)) ? DfeRb::States.now(state, @clock) : @clock.now.getlocal(DfeRb::States::DEFAULT_UTC_OFFSET)
      end

      def complete_homologacao(inf, ide)
        return unless ide["tpAmb"].to_s == "2" && ide["tpEmis"].to_s != NFF

        %w[rem exped receb dest].each do |tag|
          inf[tag]["xNome"] = HOMOLOGACAO_NAME if inf[tag].is_a?(Hash)
        end
      end

      def complete_taker_indicator(inf, ide)
        return unless ide["indIEToma"].nil?

        taker = active_taker(inf, ide) or return
        ie = taker["IE"].to_s.strip
        ide["indIEToma"] = if ie.casecmp?("ISENTO")
          2
        elsif !ie.empty?
          1
        else
          9
        end
      end

      def active_taker(inf, ide)
        return ide["toma4"] if ide["toma4"].is_a?(Hash)

        role = ide.dig("toma3", "toma")&.to_s
        tag = TAKER_PARTIES[role]
        tag && inf[tag]
      end

      def complete_service_value(inf)
        vprest = inf["vPrest"] or return
        components = Array(vprest["Comp"])
        if vprest["vTPrest"].nil? && components.any?
          vprest["vTPrest"] = components.sum(BigDecimal(0)) { |c| decimal(c["vComp"]) }.round(2, half: :up)
        end
        vprest["vRec"] = vprest["vTPrest"] if vprest["vRec"].nil? && !vprest["vTPrest"].nil?
      end

      def complete_icms(inf)
        icms = inf.dig("imp", "ICMS")
        return unless icms.is_a?(Hash)

        service_total = decimal(inf.dig("vPrest", "vTPrest"))

        if (g = icms["ICMS00"])
          g["CST"] ||= "00"
          fill_icms_math(g, service_total, base: "vBC", rate: "pICMS", amount: "vICMS")
        elsif (g = icms["ICMS20"])
          g["CST"] ||= "20"
          fill_icms_math(g, service_total, base: "vBC", rate: "pICMS", amount: "vICMS", reduction: "pRedBC")
        elsif (g = icms["ICMS90"])
          g["CST"] ||= "90"
          fill_icms_math(g, service_total, base: "vBC", rate: "pICMS", amount: "vICMS", reduction: "pRedBC")
        elsif (g = icms["ICMSOutraUF"])
          g["CST"] ||= "90"
          fill_icms_math(g, service_total, base: "vBCOutraUF", rate: "pICMSOutraUF", amount: "vICMSOutraUF", reduction: "pRedBCOutraUF")
        elsif (g = icms["ICMS60"])
          g["CST"] ||= "60"
          if g["vICMSSTRet"].nil? && g["vBCSTRet"] && g["pICMSSTRet"]
            g["vICMSSTRet"] = (decimal(g["vBCSTRet"]) * decimal(g["pICMSSTRet"]) / 100).round(2, half: :up)
          end
        elsif (g = icms["ICMSSN"])
          g["CST"] ||= "90"
          g["indSN"] ||= "1"
        end

        complete_difal(inf, service_total)
      end

      def fill_icms_math(group, service_total, base:, rate:, amount:, reduction: nil)
        if group[base].nil? && group[rate] && service_total.positive?
          factor = (reduction && group[reduction]) ? (BigDecimal(1) - decimal(group[reduction]) / 100) : BigDecimal(1)
          group[base] = (service_total * factor).round(2, half: :up)
        end
        if group[amount].nil? && group[base] && group[rate]
          group[amount] = (decimal(group[base]) * decimal(group[rate]) / 100).round(2, half: :up)
        end
      end

      def complete_difal(inf, service_total)
        difal = inf.dig("imp", "ICMSUFFim")
        return unless difal.is_a?(Hash)

        difal["vBCUFFim"] ||= service_total if service_total.positive?
        base = decimal(difal["vBCUFFim"])
        if difal["vFCPUFFim"].nil? && difal["pFCPUFFim"]
          difal["vFCPUFFim"] = (base * decimal(difal["pFCPUFFim"]) / 100).round(2, half: :up)
        end
        if difal["vICMSUFFim"].nil? && difal["pICMSUFFim"] && difal["pICMSInter"]
          diff = decimal(difal["pICMSUFFim"]) - decimal(difal["pICMSInter"])
          difal["vICMSUFFim"] = (base * [diff, BigDecimal(0)].max / 100).round(2, half: :up)
        end
        difal["vICMSUFIni"] ||= BigDecimal(0)
      end

      def complete_ibs_cbs(inf, ide)
        imp = inf["imp"]
        return unless imp.is_a?(Hash)

        ibscbs = imp["IBSCBS"]
        return unless ibscbs.is_a?(Hash)

        classification = ibscbs["cClassTrib"] && Nfe::Tables.classification(ibscbs["cClassTrib"])
        ibscbs["CST"] ||= classification.cst if classification
        issued = issued_time(ide["dhEmi"])
        year = issued&.year || @clock.now.year
        service_total = decimal(inf.dig("vPrest", "vTPrest"))

        crt = inf.dig("emit", "CRT")&.to_s
        regime = inf.dig("emit", "tpRegimeIBSCBS")&.to_s
        if (group = ibscbs["gIBSCBS"]) || classification&.taxed?
          sn_active = simples_ibs_cbs_in_force?(ide, issued)
          exempt = sn_active ? gibscbs_exempt?(crt, regime) : %w[1 2 4].include?(crt)
          group ||= (ibscbs["gIBSCBS"] = {}) if classification&.taxed? && !exempt
          if group.is_a?(Hash)
            zero_cbs = sn_active && crt == "2" && regime.nil?
            complete_gibscbs(group, classification, year, service_total, ide["gCompraGov"], zero_cbs: zero_cbs)
          end
        end

        return unless imp["vTotDFe"].nil? && !inf.dig("vPrest", "vTPrest").nil?

        imp["vTotDFe"] = if year >= 2027
          ibs = decimal(ibscbs.dig("gIBSCBS", "vIBS"))
          cbs = decimal(ibscbs.dig("gIBSCBS", "gCBS", "vCBS"))
          (service_total + ibs + cbs).round(2, half: :up)
        else
          service_total.round(2, half: :up)
        end
      end

      def simples_ibs_cbs_in_force?(ide, issued)
        since = Validator::SIMPLES_IBS_CBS_SINCE[ide["tpAmb"].to_s] or return false
        (issued || @clock.now) >= since
      end

      def gibscbs_exempt?(crt, regime)
        crt == "4" || (crt == "1" && regime.nil?)
      end

      def complete_gibscbs(group, classification, year, service_total, gov, zero_cbs: false)
        group["vBC"] = service_total if group["vBC"].nil? && service_total.positive?
        base = decimal(group["vBC"])
        standard = Nfe::Rates.ibs_cbs(year)
        gov_reduction = (gov && gov["pRedutor"]) ? decimal(gov["pRedutor"]) : nil

        uf = (group["gIBSUF"] ||= {})
        mun = (group["gIBSMun"] ||= {})
        cbs = (group["gCBS"] ||= {})

        zero_main = classification&.regular_taxation?
        uf["pIBSUF"] ||= zero_main ? BigDecimal(0) : standard[:uf]
        mun["pIBSMun"] ||= zero_main ? BigDecimal(0) : standard[:municipal]
        cbs["pCBS"] ||= (zero_main || zero_cbs) ? BigDecimal(0) : standard[:cbs]

        ibs_red = classification&.rate_reduction? ? classification.ibs_reduction : nil
        cbs_red = classification&.rate_reduction? ? classification.cbs_reduction : nil

        complete_ibs_cbs_leg(uf, base, rate_key: "pIBSUF", amount_key: "vIBSUF", default_reduction: ibs_red, gov_reduction: gov_reduction)
        complete_ibs_cbs_leg(mun, base, rate_key: "pIBSMun", amount_key: "vIBSMun", default_reduction: ibs_red, gov_reduction: gov_reduction)
        group["vIBS"] ||= (decimal(uf["vIBSUF"]) + decimal(mun["vIBSMun"])).round(2, half: :up)
        complete_ibs_cbs_leg(cbs, base, rate_key: "pCBS", amount_key: "vCBS", default_reduction: cbs_red, gov_reduction: gov_reduction)
      end

      def complete_ibs_cbs_leg(leg, base, rate_key:, amount_key:, default_reduction:, gov_reduction:)
        rate_val = leg[rate_key]
        return if rate_val.nil?

        rate = decimal(rate_val)
        if leg["gRed"].nil? && (default_reduction&.positive? || gov_reduction)
          leg["gRed"] = {"pRedAliq" => default_reduction || BigDecimal(0)}
        end
        if (red = leg["gRed"])
          red["pRedAliq"] ||= default_reduction || BigDecimal(0)
          if red["pAliqEfet"].nil?
            eff = rate * (BigDecimal(1) - decimal(red["pRedAliq"]) / 100)
            eff *= (BigDecimal(1) - gov_reduction / 100) if gov_reduction
            red["pAliqEfet"] = eff.round(4, half: :up)
          end
        end
        applied_rate = leg["gRed"] ? decimal(leg.dig("gRed", "pAliqEfet")) : rate
        if (dif = leg["gDif"]) && dif["vDif"].nil? && dif["pDif"]
          dif["vDif"] = (base * applied_rate / 100 * decimal(dif["pDif"]) / 100).round(2, half: :up)
        end
        return unless leg[amount_key].nil?

        gross = base * applied_rate / 100
        deductions = decimal(leg.dig("gDif", "vDif")) + decimal(leg.dig("gDevTrib", "vDevTrib"))
        leg[amount_key] = [gross - deductions, BigDecimal(0)].max.round(2, half: :up)
      end

      def complete_cargo(inf)
        measures = Array(inf.dig("infCTeNorm", "infCarga", "infQ"))
        measures.each do |measure|
          next unless measure.is_a?(Hash)

          unit = measure["cUnid"].to_s.rjust(2, "0") if measure["cUnid"]
          measure["cUnid"] = unit if unit
          measure["tpMed"] ||= MEASURE_DEFAULTS[unit] if unit
        end
      end

      def complete_billing(inf)
        cobr = inf.dig("infCTeNorm", "cobr") or return
        Array(cobr["dup"]).each_with_index do |dup, index|
          dup["nDup"] ||= format("%03d", index + 1) if dup.is_a?(Hash)
        end
      end

      def complete_payment_links(inf)
        Array(inf.dig("pgtoVinc", "pgto")).each_with_index do |entry, index|
          entry["@nPag"] ||= (index + 1).to_s if entry.is_a?(Hash)
        end
      end

      def identify(inf, ide, emit)
        tax_id = emit["CNPJ"] || emit["CPF"]
        return unless tax_id && ide["cUF"] && ide["nCT"] && ide["dhEmi"]

        issued_at = issued_time(ide["dhEmi"])
        return unless key_parts_valid?(ide, issued_at)

        key = AccessKey.build(
          state: ide["cUF"], issued_at: issued_at, tax_id: tax_id, series: ide["serie"].to_i,
          number: ide["nCT"].to_i, numeric_code: ide["cCT"], model: ide["mod"].to_i,
          emission_type: ide["tpEmis"].to_i
        )
        ide["cDV"] = key.check_digit
        inf["@Id"] = key.id
        inf["@versao"] = Schema::VERSION
      rescue ArgumentError => e
        @issues << "cannot build the access key: #{e.message}"
      end

      def key_parts_valid?(ide, issued_at)
        problems = []
        problems << "ide/dhEmi: #{ide["dhEmi"].inspect} is not a date and time (e.g. 2026-09-29T10:00:00-03:00)" unless issued_at
        problems << "ide/serie: #{ide["serie"]} is not a series (0 to 999)" unless digits?(ide["serie"], 0..999)
        problems << "ide/nCT: #{ide["nCT"]} is not a waybill number (1 to 999999999)" unless digits?(ide["nCT"], 1..999_999_999)
        problems << "ide/cCT: #{ide["cCT"]} is not an 8-digit numeric code" unless ide["cCT"].to_s.match?(/\A\d{1,8}\z/)
        problems << "ide/tpEmis: #{ide["tpEmis"]} is not an emission type (1, 2, 3, 4, 7 or 8)" unless %w[1 2 3 4 7 8].include?(ide["tpEmis"].to_s)
        problems << "ide/mod: #{ide["mod"]} is not the CT-e's model (57)" unless ide["mod"].to_s == AccessKey::MODEL.to_s
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

      def decimal(value)
        return BigDecimal(0) if value.nil? || value.to_s.strip.empty?

        BigDecimal(value.to_s)
      rescue ArgumentError
        BigDecimal(0)
      end

      def technical_contact(inf)
        contact = inf["infRespTec"]
        return unless contact

        if contact["idCSRT"].to_s.match?(/\A\d{1,2}\z/)
          contact["idCSRT"] = contact["idCSRT"].to_s.rjust(3, "0")
        end
        return unless @csrt && inf["@Id"]

        contact["hashCSRT"] ||= Base64.strict_encode64(Digest::SHA1.digest("#{@csrt}#{inf["@Id"].delete_prefix("CTe")}"))
      end
    end
  end
end
