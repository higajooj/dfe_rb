require "bigdecimal"

module DfeRb
  module Nfse
    # The rules of Anexo I (RN DPS_NFS-e) that need nothing but the DPS: identities and
    # check digits, what each issuer type may fill, the Simples Nacional and special
    # regimes against rates and withholdings, values against the service's, the groups some
    # service codes require, and the IBS/CBS group's own consistency. What needs the
    # national registers (CNC, CNPJ, the municipality's parameters, the IBS/CBS calculator)
    # is left to the Sefin. Each message names its error code, such as "(E0600)".
    class Validator
      PROVIDER = "1"
      TAKER = "2"
      INTERMEDIARY = "3"
      MEI = "2"
      ME_EPP = "3"
      NOT_TAXABLE = Names::ENUMS["tribISSQN"].values_at(:immune, :export, :not_levied).map(&:to_s).freeze
      OWN_APPLICATION_SERIES = 1..49_999
      SERIES = Layout::SERIES
      CONSTRUCTION = %w[070201 070202 070401 070501 070502 070601 070602 070701 070801 071701 071901 141403 141404].freeze
      CONSTRUCTION_OPTIONAL = "990101"
      CIVIL_CONSTRUCTION = %w[070201 070202 070401 070501 070502 070601 070602 070701 070801 071701 071901].freeze
      REAL_ESTATE_OPERATIONS = {v1_01: %w[020101 020201 020301], nt009: %w[020101 020201 020202 020301 020401]}.freeze
      OPERATION_TYPE_SERVICES = %w[2505 1509 1712 1005].freeze
      IBS_CBS_SINCE = Date.new(2026, 1, 1)
      # NT 009 makes the IBS/CBS group mandatory from this competence (E0855); its layout's
      # note puts the Simples Nacional's from 2027.
      IBS_CBS_REQUIRED_SINCE = Date.new(2026, 10, 1)
      IBS_CBS_REQUIRED_SIMPLES_SINCE = Date.new(2027, 1, 1)
      TOLERANCE = BigDecimal("0.01")

      def initialize(infdps, layout:)
        @inf = infdps
        @layout = layout
        @issues = []
      end

      def issues
        @issues = []
        identification
        parties
        tax_regime
        service
        values
        municipal_tax
        federal_taxes
        approximate_taxes
        ibs_cbs
        @issues
      end

      private

      attr_reader :inf

      def add(message) = @issues << message

      def issuer_type = inf["tpEmit"].to_s

      def provider = inf["prest"] || {}

      def taker = inf["toma"]

      def intermediary = inf["interm"]

      def regime = provider.dig("regTrib") || {}

      def simples = regime["opSimpNac"].to_s

      def special_regime = regime["regEspTrib"].to_s

      def values_group = inf["valores"] || {}

      def tribmun = values_group.dig("trib", "tribMun") || {}

      def issqn = tribmun["tribISSQN"].to_s

      def withholding = tribmun["tpRetISSQN"].to_s

      def service_amount = decimal(values_group.dig("vServPrest", "vServ"))

      def national_code = inf.dig("serv", "cServ", "cTribNac").to_s

      def competence
        value = inf["dCompet"]
        value.is_a?(Date) ? value : Date.parse(value.to_s)
      rescue Date::Error
        nil
      end

      def identification
        expected = Resolver.id(city: inf["cLocEmi"], tax_id: issuer_tax_id, series: inf["serie"], number: inf["nDPS"])
        add("infDPS/@Id: #{inf["@Id"]} is not \"DPS\" + cLocEmi + the issuer's inscription + serie + nDPS (#{expected}) (E0004)") if expected && inf["@Id"] != expected

        series = inf["serie"].to_s
        if !series.match?(SERIES)
          add("serie: #{series.inspect} is not a series (1 to 5 digits)")
        elsif !OWN_APPLICATION_SERIES.cover?(series.to_i)
          add("serie: #{series} is outside 1 to 49999, the series of a DPS sent by the issuer's own application (E0010)")
        end

        city(inf["cLocEmi"], "cLocEmi", "E1304")
        issued_on = date_of(inf["dhEmi"])
        add("dCompet: #{competence} is after the day of dhEmi, #{issued_on} (E0015)") if competence && issued_on && competence > issued_on

        replacement
        issuer_reason
      end

      def replacement
        group = inf["subst"] or return

        add("subst/xMotivo: describe the reason when cMotivo is 99 (E0078)") if group["cMotivo"].to_s == "99" && blank?(group["xMotivo"])
      end

      def issuer_reason
        reason = inf["cMotivoEmisTI"].to_s
        if issuer_type == PROVIDER
          add("cMotivoEmisTI: only a DPS the taker or the intermediary issues says why (E0029)") unless reason.empty?
        elsif @layout.nt009? && reason != "1"
          add("cMotivoEmisTI: a DPS the taker or the intermediary issues must give 1, the import of a service (E0031)")
        end
      end

      def issuer_tax_id
        party = {PROVIDER => provider, TAKER => taker, INTERMEDIARY => intermediary}[issuer_type] || {}
        party["CNPJ"] || party["CPF"]
      end

      def parties
        party(provider, "prest", cnpj: "E0080", cpf: "E0096", no_nif: "E0115")
        party(taker, "toma", cnpj: "E0188", cpf: "E0206", no_nif: "E0226", city: "E0238") if taker
        party(intermediary, "interm", cnpj: "E0248", cpf: "E0266", no_nif: "E0286", city: "E0294") if intermediary
        issuer_party
        taker_rules
        intermediary_rules
      end

      def party(data, path, cnpj:, cpf:, no_nif:, city: "E0130")
        add("#{path}/CNPJ: #{data["CNPJ"]} has a wrong check digit (#{cnpj})") if data["CNPJ"] && !TaxId.valid_cnpj?(data["CNPJ"].to_s)
        add("#{path}/CPF: #{data["CPF"]} has a wrong check digit (#{cpf})") if data["CPF"] && !TaxId.valid_cpf?(data["CPF"].to_s)
        add("#{path}/cNaoNIF: 0 (not informed on the original note) is refused (#{no_nif})") if data["cNaoNIF"].to_s == "0"
        city(data.dig("end", "endNac", "cMun"), "#{path}/end/endNac/cMun", city) if data.dig("end", "endNac")
      end

      def issuer_party
        if issuer_type == PROVIDER
          add("prest/NIF: the provider issuing the DPS is identified by CNPJ or CPF (E0112)") if provider["NIF"]
          add("prest/cNaoNIF: the provider issuing the DPS is identified by CNPJ or CPF (E0114)") if provider.key?("cNaoNIF")
          add("prest/xNome: leave the name of the provider issuing the DPS out; the Sefin takes it from the CNPJ or CPF (E0121)") if provider["xNome"]
          add("prest/end: leave the address of the provider issuing the DPS out; the Sefin takes it from the registers (E0128)") if provider["end"]
        else
          add("prest/xNome: name the provider when the taker or the intermediary issues the DPS (E0122)") if blank?(provider["xNome"])
          add("prest/end: give the provider's address when the taker or the intermediary issues the DPS (E0129)") unless provider["end"]
        end
        add("prest/xNome: a provider identified by NIF is named (E0123)") if provider["NIF"] && blank?(provider["xNome"])
        add("infoCompl/docRef: a DPS the taker or the intermediary issues references a document (E0420)") if issuer_type != PROVIDER && blank?(inf.dig("serv", "infoCompl", "docRef"))
      end

      def taker_rules
        if withholding == "2" && !(taker && (taker["CNPJ"] || taker["CPF"]))
          add("toma: an ISSQN withheld by the taker (tpRetISSQN 2) needs the taker's CNPJ or CPF (E0204)")
        end
        if withholding == "3" && !(intermediary && (intermediary["CNPJ"] || intermediary["CPF"]))
          add("interm: an ISSQN withheld by the intermediary (tpRetISSQN 3) needs the intermediary's CNPJ or CPF (E0264)")
        end
        return unless taker

        if taker["CNPJ"] && taker["CNPJ"] == provider["CNPJ"]
          add("toma/CNPJ: the taker is the provider (E0202)")
        end
        named = @layout.nt009? ? (taker["CNPJ"] || taker["CPF"] || taker["NIF"]) : taker["NIF"]
        add("toma/xNome: name the taker identified by #{@layout.nt009? ? "CNPJ, CPF or NIF" : "NIF"} (E0233)") if named && blank?(taker["xNome"])
        if issuer_type == PROVIDER && taker["CNPJ"] && !taker.dig("end", "endNac")
          add("toma/end/endNac: give the address in Brazil of a taker identified by CNPJ (E0235)")
        end
        if withholding == "2" && issuer_type != TAKER && !taker.dig("end", "endNac")
          add("toma/end/endNac: give the address in Brazil of a taker who withholds the ISSQN (E0237)")
        end
        if (taker["NIF"] || taker.key?("cNaoNIF")) && !taker.dig("end", "endExt")
          add("toma/end/endExt: give the address abroad of a taker identified by NIF or cNaoNIF (E0242)")
        end
      end

      def intermediary_rules
        return unless intermediary

        add("interm/xNome: name the intermediary identified by NIF (E0292)") if intermediary["NIF"] && blank?(intermediary["xNome"])
        if issuer_type == PROVIDER && intermediary["CNPJ"] && !intermediary.dig("end", "endNac")
          add("interm/end/endNac: give the address in Brazil of an intermediary identified by CNPJ (E1388)")
        end
        if intermediary["CNPJ"] && provider["CNPJ"] && intermediary["CNPJ"].to_s[0, 8] == provider["CNPJ"].to_s[0, 8]
          add("interm/CNPJ: the intermediary has the provider's CNPJ root (E0262)")
        end
      end

      def tax_regime
        apuracao = regime["regApTribSN"]
        if simples == ME_EPP
          add("prest/regTrib/regApTribSN: an ME/EPP of the Simples Nacional says how it pays its taxes (E0166)") if blank?(apuracao)
        elsif apuracao
          add("prest/regTrib/regApTribSN: only an ME/EPP of the Simples Nacional (opSimpNac 3) gives it (E0162)")
        end
        return if special_regime.empty? || special_regime == "0"

        add("prest/regTrib/regEspTrib: a MEI has no special regime (E0174)") if simples == MEI
        add("prest/regTrib/regEspTrib: a service not taxed by the ISSQN (tribISSQN #{issqn}) has no special regime (E0172)") if NOT_TAXABLE.include?(issqn)
      end

      def service
        place = inf.dig("serv", "locPrest", "cLocPrestacao")
        city(place, "serv/locPrest/cLocPrestacao", "E0302") unless place.nil? || place.to_s == "0000000"
        add("serv/cServ/cTribMun: 000 is refused (E0315)") if inf.dig("serv", "cServ", "cTribMun").to_s == "000"
        if @layout.nt009? && (national_code.start_with?("9903") || national_code == "990401")
          add("serv/cServ/cTribNac: #{national_code} is refused (E0309)")
        end
        if inf["IBSCBS"] && blank?(inf.dig("serv", "cServ", "cNBS"))
          add("serv/cServ/cNBS: a DPS with the IBS/CBS group names the service's NBS item (E0322)")
        end
        construction
        event
        foreign_trade
      end

      def construction
        return if national_code.empty?

        given = inf.dig("serv", "obra")
        if CONSTRUCTION.include?(national_code) && !given
          add("serv/obra: the construction service #{national_code} carries the obra group (E0370)")
        elsif given && !CONSTRUCTION.include?(national_code) && national_code != CONSTRUCTION_OPTIONAL
          add("serv/obra: only the construction services and 99.01.01 take the obra group, not #{national_code} (E0372)")
        end
      end

      def event
        return if national_code.empty?

        add("serv/atvEvento: a service of item 12 carries the atvEvento group (E0390)") if national_code.start_with?("12") && !inf.dig("serv", "atvEvento")
      end

      def foreign_trade
        trade = inf.dig("serv", "comExt") or return

        movement = trade["movTempBens"].to_s
        add("serv/comExt/nDI: give the import declaration when movTempBens is 2 (E0352)") if movement == "2" && blank?(trade["nDI"])
        add("serv/comExt: no nDI or nRE when movTempBens is 1 (E0354)") if movement == "1" && (trade["nDI"] || trade["nRE"])
        add("serv/comExt/nRE: give the export registration when movTempBens is 3 (E0356)") if movement == "3" && blank?(trade["nRE"])
      end

      def values
        amount = service_amount
        received = values_group.dig("vServPrest", "vReceb")
        if issuer_type == INTERMEDIARY
          add("valores/vServPrest/vReceb: the intermediary issuing the DPS gives the amount it received (E0423)") if received.nil?
        elsif received
          add("valores/vServPrest/vReceb: only the intermediary issuing the DPS gives it (E0424)")
        end
        received_amount = decimal(received)
        if received_amount && amount && received_amount < amount
          add("valores/vServPrest/vReceb: #{received} is less than vServ, #{amount.to_s("F")} (E0425)")
        end

        {"vDescIncond" => "E0431", "vDescCond" => "E0432"}.each do |tag, code|
          discount = decimal(values_group.dig("vDescCondIncond", tag)) or next
          next unless amount

          add("valores/vDescCondIncond/#{tag}: must be more than zero and less than vServ (#{code})") unless discount.positive? && discount < amount
        end

        path = @layout.nt009? ? %w[vAjusteBC pAjusteBCISSQN] : %w[vDedRed pDR]
        rate = decimal(values_group.dig(*path))
        add("valores/#{path.join("/")}: must be more than 0 and at most 100 (E0453)") if rate && !(rate.positive? && rate <= 100)
      end

      def municipal_tax
        rate = decimal(tribmun["pAliq"])
        withheld = %w[2 3].include?(withholding)
        if NOT_TAXABLE.include?(issqn)
          add("valores/trib/tribMun/tpRetISSQN: no ISSQN is withheld on a service it doesn't tax (tribISSQN #{issqn}) (E0580)") if withheld
          add("valores/trib/tribMun/pAliq: no rate on a service the ISSQN doesn't tax (tribISSQN #{issqn}) (E0602)") if rate
        end
        if simples == MEI
          add("valores/trib/tribMun/tpRetISSQN: a MEI's ISSQN is not withheld (E0583)") if withheld
          add("valores/trib/tribMun/pAliq: a MEI gives no rate (E0600)") if rate
        end
        if !special_regime.empty? && special_regime != "0"
          add("valores/trib/tribMun/tpRetISSQN: no ISSQN is withheld under a special regime (regEspTrib #{special_regime}) (E0588)") if withheld
          add("valores/trib/tribMun/pAliq: no rate under a special regime (regEspTrib #{special_regime}) (E0604)") if rate
        end
        add("valores/trib/tribMun/pAliq: #{rate.to_s("F")} is more than 5% (E0595)") if rate && rate > 5
        add("valores/trib/tribMun/tpRetISSQN: the taker issuing the DPS withholds the ISSQN (2) (E0650)") if @layout.nt009? && issuer_type == TAKER && withholding != "2"
        add("valores/trib/tribMun/tpRetISSQN: the intermediary issuing the DPS withholds the ISSQN (3) (E0652)") if @layout.nt009? && issuer_type == INTERMEDIARY && withholding != "3"
      end

      def federal_taxes
        federal = values_group.dig("trib", "tribFed") or return
        return add("valores/trib/tribFed: a MEI informs no federal taxes (E0676)") if simples == MEI

        amount = service_amount
        pis_cofins(federal["piscofins"], amount) if federal["piscofins"]
        {"vRetCP" => "E0699", "vRetIRRF" => "E0700", "vRetCSLL" => "E0701"}.each do |tag, code|
          value = decimal(federal[tag]) or next
          next unless amount

          add("valores/trib/tribFed/#{tag}: must be more than zero and less than vServ (#{code})") unless value.positive? && value < amount
        end
        kind = federal.dig("piscofins", "tpRetPisCofins").to_s
        add("valores/trib/tribFed/vRetCSLL: the CSLL is not withheld (tpRetPisCofins 0) (E0720)") if kind == "0" && federal["vRetCSLL"]
        if !kind.empty? && !%w[0 2].include?(kind) && federal["vRetCSLL"].nil?
          add("valores/trib/tribFed/vRetCSLL: give the CSLL withheld (tpRetPisCofins #{kind}) (E0724)")
        end
      end

      def pis_cofins(group, amount)
        base = decimal(group["vBCPisCofins"])
        add("valores/trib/tribFed/piscofins/vBCPisCofins: more than vServ (E0677)") if base && amount && base > amount
        {["pAliqPis", "vPis"] => %w[E0686 E0694], ["pAliqCofins", "vCofins"] => %w[E0692 E0696]}.each do |(rate_tag, value_tag), (range, product)|
          rate = decimal(group[rate_tag]) or next

          add("valores/trib/tribFed/piscofins/#{rate_tag}: must be between 0 and 100 (#{range})") unless rate.between?(0, 100)
          value = decimal(group[value_tag])
          next unless base && value

          # Rounded half to even, within a cent (NT 007, 2.c).
          expected = (base * rate / 100).round(2, half: :even)
          add("valores/trib/tribFed/piscofins/#{value_tag}: #{value.to_s("F")} is not vBCPisCofins x #{rate_tag} (#{expected.to_s("F")}) (#{product})") if (value - expected).abs > TOLERANCE
        end
      end

      def approximate_taxes
        totals = values_group.dig("trib", "totTrib")
        if totals.nil? || totals.empty?
          return add("valores/trib/totTrib: give the approximate taxes (approximate_taxes federal:, state:, municipal:, rates: or simples_rate:)")
        end

        amount = service_amount
        {"vTotTribFed" => "E0702", "vTotTribEst" => "E0703", "vTotTribMun" => "E0704"}.each do |tag, code|
          value = decimal(totals.dig("vTotTrib", tag))
          add("valores/trib/totTrib/vTotTrib/#{tag}: more than vServ (#{code})") if value && amount && value > amount
        end
        {"pTotTribFed" => "E0706", "pTotTribEst" => "E0707", "pTotTribMun" => "E0708"}.each do |tag, code|
          value = decimal(totals.dig("pTotTrib", tag))
          add("valores/trib/totTrib/pTotTrib/#{tag}: more than 100% (#{code})") if value && value > 100
        end
        add("valores/trib/totTrib/indTotTrib: an ME/EPP of the Simples Nacional informs its approximate taxes (E0712)") if simples == ME_EPP && totals.key?("indTotTrib")
        if simples == "1" && (totals.key?("indTotTrib") || totals.key?("pTotTribSN"))
          add("valores/trib/totTrib: a provider outside the Simples Nacional informs its approximate taxes as amounts or rates (E0713)")
        end
        add("valores/trib/totTrib/pTotTribSN: a MEI has no Simples Nacional rate to give (E0710)") if simples == MEI && totals.key?("pTotTribSN")
      end

      def ibs_cbs
        group = inf["IBSCBS"]
        date = competence
        unless group
          return unless @layout.nt009? && date && date >= IBS_CBS_REQUIRED_SINCE

          since = %w[2 3].include?(simples) ? IBS_CBS_REQUIRED_SIMPLES_SINCE : IBS_CBS_REQUIRED_SINCE
          add("IBSCBS: a DPS of a competence from #{since.strftime("%d/%m/%Y")} declares the IBS and the CBS (E0855)") if date >= since
          return
        end

        add("IBSCBS: only a competence from 01/01/2026 declares the IBS and the CBS (E0850)") if date && date < IBS_CBS_SINCE
        recipient(group)
        operation_type(group)
        classification(group)
        real_estate(group)
      end

      def recipient(group)
        indicator = group["indDest"].to_s
        add("IBSCBS/dest: no recipient when indDest is 0, the taker (E0908)") if indicator == "0" && group["dest"]
        add("IBSCBS/dest: name the recipient when indDest is 1 (E0910)") if indicator == "1" && !group["dest"]
        dest = group["dest"] or return

        add("IBSCBS/dest/CNPJ: #{dest["CNPJ"]} has a wrong check digit (E0911)") if dest["CNPJ"] && !TaxId.valid_cnpj?(dest["CNPJ"].to_s)
        add("IBSCBS/dest/CPF: #{dest["CPF"]} has a wrong check digit (E0913)") if dest["CPF"] && !TaxId.valid_cpf?(dest["CPF"].to_s)
        city(dest.dig("end", "endNac", "cMun"), "IBSCBS/dest/end/endNac/cMun", "E0920") if dest.dig("end", "endNac")
        add("IBSCBS/dest/end/endExt: give the address abroad of a recipient identified by NIF or cNaoNIF (E0923)") if (dest["NIF"] || dest.key?("cNaoNIF")) && !dest.dig("end", "endExt")
      end

      def operation_type(group)
        kind = group["tpOper"].to_s
        listed = OPERATION_TYPE_SERVICES.include?(national_code[0, 4])
        if kind.empty?
          add("IBSCBS/tpOper: give it for a government entity or the service #{national_code} (E0903)") if group["tpEnteGov"] || listed
        elsif !(group["tpEnteGov"] || listed)
          add("IBSCBS/tpOper: only a government entity (tpEnteGov) or the services 25.05, 15.09, 17.12 and 10.05 take it (E0904)")
        end
        referenced = group["gRefNFSe"]
        add("IBSCBS/gRefNFSe: reference the notes of a supply already made or paid (tpOper #{kind}) (E0905)") if %w[2 3].include?(kind) && !referenced
        add("IBSCBS/gRefNFSe: only tpOper 2 or 3 references notes (E0906)") if referenced && !%w[2 3].include?(kind)
      end

      def classification(group)
        trib = group.dig("valores", "trib") || {}
        main = @layout.nt009? ? trib : (trib["gIBSCBS"] || {})
        cst = main["CST"].to_s
        code = main["cClassTrib"].to_s
        add("IBSCBS: cClassTrib #{code} is not of CST #{cst}: its first three digits are the CST (E0959)") if !cst.empty? && !code.empty? && code[0, 3] != cst
        regular = trib.dig("gIBSCBS", "gTribRegular") or return

        if regular["cClassTribReg"].to_s[0, 3] != regular["CSTReg"].to_s
          add("IBSCBS/gTribRegular: cClassTribReg #{regular["cClassTribReg"]} is not of CSTReg #{regular["CSTReg"]} (E0970)")
        end
      end

      def real_estate(group)
        property = group["imovel"]
        operation = REAL_ESTATE_OPERATIONS.fetch(@layout.name).include?(group["cIndOp"].to_s)
        if CIVIL_CONSTRUCTION.include?(national_code)
          add("IBSCBS/imovel: the construction service #{national_code} takes no imovel group (E0931)") if property
        elsif operation && !property
          add("IBSCBS/imovel: the real estate operation #{group["cIndOp"]} carries the imovel group (E0932)")
        elsif property && !operation
          add("IBSCBS/imovel: only a real estate operation (cIndOp #{REAL_ESTATE_OPERATIONS.fetch(@layout.name).join(", ")}) takes the imovel group (E0928)")
        end
        return unless @layout.nt009?

        rental = national_code.start_with?("9903")
        if property
          city(property["cMun"], "IBSCBS/imovel/cMun", "E0929")
          add("IBSCBS/imovel/gLocacao: only the service 99.03 takes it (E0936)") if property["gLocacao"] && !rental
          add("IBSCBS/imovel/gLocacao: the service 99.03 carries it (E0937)") if rental && !property["gLocacao"]
        end
        goods = group["bensMoveis"]
        add("IBSCBS/bensMoveis: only the service 99.04.01 takes it (E0967)") if goods && national_code != "990401"
        add("IBSCBS/bensMoveis: the service 99.04.01 carries it (E0963)") if !goods && national_code == "990401"
      end

      def city(code, path, rule)
        return if code.nil?

        add("#{path}: #{code} is not a municipality of the IBGE table (#{rule})") unless Cities.name(code)
      end

      def decimal(value)
        return if value.nil? || value.to_s.strip.empty?

        BigDecimal(value.to_s)
      rescue ArgumentError
        nil
      end

      def date_of(value)
        return value.to_date if value.respond_to?(:to_date) && !value.is_a?(String)

        Time.iso8601(value.to_s).to_date
      rescue ArgumentError
        nil
      end

      def blank?(value) = value.nil? || value.to_s.strip.empty?
    end
  end
end
