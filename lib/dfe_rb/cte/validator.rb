require "bigdecimal"
require "date"
require "time"

module DfeRb
  module Cte
    class Validator
      TOLERANCE = BigDecimal("0.01")
      MAX_SERVICE_VALUE = BigDecimal("9999999.99")
      MAX_DOCUMENTS = 2000
      MONTHS_KEPT = 6
      COMPLEMENT_MONTHS = 12
      COMPLEMENT_EXTENDED_MONTHS = 24
      RESERVED_SERIES = (890..899)
      EXTERIOR = "EX"
      EXTERIOR_CITY = "9999999"
      HOMOLOGACAO_NAME = Resolver::HOMOLOGACAO_NAME

      NORMAL = "0"
      COMPLEMENTARY = "1"
      SUBSTITUTION = "3"

      SERV_NORMAL = "0"
      SERV_SUBCONTRACTING = "1"
      SERV_REDISPATCH = "2"
      SERV_INTERMEDIATE_REDISPATCH = "3"
      SERV_MULTIMODAL_LINKED = "4"

      EMIS_NORMAL = "1"
      EMIS_OFFLINE = "2"
      EMIS_NFF = "3"
      EMIS_EPEC = "4"
      EMIS_SVC_RS = "7"
      EMIS_SVC_SP = "8"

      MODAL_WATER = "03"
      MODAL_RAIL = "04"
      MODAL_PIPELINE = "05"

      NO_EXEMPT_IE_STATES = %w[AM BA CE GO MG MS MT PE RN SE SP PI PA RJ].freeze
      SUFRAMA_STATES = %w[AC AM RO RR].freeze
      SUFRAMA_AP_CITIES = %w[1600303 1600600].freeze

      PARTY_CHECKS = {
        "rem" => {addr: "enderReme", cnpj: [415, "G114"], cpf: [416, "G115"], city_uf: [418, "G116"], city: [532, "G117"], hom: [646, "G002"]},
        "exped" => {addr: "enderExped", cnpj: [428, "G132"], cpf: [429, "G133"], city_uf: [431, "G134"], city: [534, "G135"], hom: [647, "G003"]},
        "receb" => {addr: "enderReceb", cnpj: [436, "G140"], cpf: [437, "G141"], city_uf: [439, "G142"], city: [535, "G143"], hom: [648, "G004"]},
        "dest" => {addr: "enderDest", cnpj: [208, "G122"], cpf: [237, "G123"], city_uf: [424, "G124"], city: [533, "G125"], hom: [649, "G005"]}
      }.freeze
      TAKER_ROLES = {
        "0" => ["rem", "sender", "G018", 460],
        "1" => ["exped", "dispatcher", "G019", 461],
        "2" => ["receb", "receiver", "G020", 462],
        "3" => ["dest", "recipient", "G021", 463]
      }.freeze

      def initialize(infcte, qr_code: nil, clock: Time, csrt: nil, signer: nil, qr_code_base_url: nil)
        @inf = infcte
        @ide = infcte["ide"] || {}
        @emit = infcte["emit"] || {}
        @norm = infcte["infCTeNorm"]
        @qr_code = qr_code
        @clock = clock
        @csrt = csrt
        @signer = signer
        @qr_code_base_url = qr_code_base_url
        @issues = []
      end

      def issues
        @issues = []
        check_issuer
        check_identification
        check_key
        check_locations
        check_cfop
        check_parties
        check_taker
        check_service_and_documents
        check_values_and_icms
        check_ibs_cbs
        check_modals
        check_substitution_and_complement
        check_globalized
        check_authorized
        check_payment_links
        check_qr_code
        check_technical_contact
        @issues
      end

      private

      def add(message) = @issues << message

      def cte_type = @ide["tpCTe"].to_s

      def service_type = @ide["tpServ"].to_s

      def emission_type = @ide["tpEmis"].to_s

      def nff? = emission_type == EMIS_NFF

      def normal_or_sub? = [NORMAL, SUBSTITUTION].include?(cte_type)

      def issuer_id = @emit["CNPJ"] || @emit["CPF"]

      def check_issuer
        cnpj, cpf = @emit.values_at("CNPJ", "CPF")
        add "emit/CNPJ: #{cnpj} is not a valid CNPJ (G104, rej. 207)" if cnpj && !TaxId.valid_cnpj?(cnpj.to_s)
        add "emit/CPF: #{cpf} is not a valid CPF (G104, rej. 207)" if cpf && !TaxId.valid_cpf?(cpf.to_s)
        add "emit: give the issuer's CNPJ or CPF" if cnpj.nil? && cpf.nil?
        add "emit/IE: the issuer's state registration is required (G105, rej. 229)" if !nff? && @inf["infPAA"].nil? && @emit["IE"].to_s.delete("0").empty?
        add "emit/CRT: an issuer using PAA must be MEI, CRT 4 (G111c, rej. 917)" if @inf["infPAA"] && @emit["CRT"].to_s != "4"

        addr = @emit["enderEmit"] || {}
        city, state = addr["cMun"].to_s, addr["UF"]
        return if city.empty? || state.nil?

        unless nff?
          add "emit/enderEmit/cMun: city #{city} does not belong to #{state} (G112, rej. 712)" unless belongs?(city, state)
          if @ide["cUF"] && DfeRb::States::CODES[state] && @ide["cUF"].to_s != DfeRb::States.code(state)
            add "ide/cUF: #{@ide["cUF"]} is not the issuer's state, #{state} (G007, rej. 247)"
          end
        end
        add "emit/enderEmit/cMun: #{city} is not in the IBGE table of cities (G113, rej. 713)" unless Cities.name(city)
      end

      def check_identification
        add "ide/nCT: the waybill number is required" if @ide["nCT"].nil?
        add "ide/serie: series #{RESERVED_SERIES.min} to #{RESERVED_SERIES.max} are reserved (G006, rej. 670)" if !nff? && RESERVED_SERIES.cover?(@ide["serie"].to_i)
        add "infSolicNFF: only for the Nota Fiscal Fácil, tpEmis 3 (G218, rej. 902)" if @inf["infSolicNFF"] && !nff?

        if emission_type == EMIS_OFFLINE
          add "ide/dhCont: contingency timestamp and reason are required for offline emission (G009, rej. 587)" if @ide["dhCont"].nil? || @ide["xJust"].to_s.empty?
        elsif @ide["dhCont"] || @ide["xJust"]
          add "ide/dhCont: contingency timestamp and reason are for offline emission (tpEmis 2) only (G008, rej. 586)"
        end

        if [EMIS_SVC_RS, EMIS_SVC_SP].include?(emission_type) && cte_type != NORMAL
          add "ide/tpCTe: a CT-e issued in SVC contingency must be normal, tpCTe 0 (G012, rej. 517)"
        end
        if emission_type == EMIS_EPEC && cte_type != NORMAL
          add "ide/tpCTe: a CT-e issued under EPEC must be normal, tpCTe 0 (G184, rej. 720)"
        end

        if normal_or_sub? && @norm.nil?
          add "infCTeNorm: required for a normal or substitution CT-e (G016, rej. 458)"
        elsif cte_type == COMPLEMENTARY && Array(@inf["infCteComp"]).empty?
          add "infCteComp: required for a complementary CT-e (G017, rej. 459)"
        end

        issued = time(@ide["dhEmi"]) or return
        cont = time(@ide["dhCont"])
        add "ide/dhCont: contingency time is after emission time (G010, rej. 588)" if cont && cont > issued

        now = @clock.now
        add "ide/dhEmi: #{issued.iso8601} is in the future (G102, rej. 212)" if issued > now + 300
        late_exempt = [EMIS_OFFLINE, EMIS_EPEC].include?(emission_type) || @ide["gMultaJuros"] || @ide["gPagAntecipado"]
        if !late_exempt && issued < now - 168 * 3600
          add "ide/dhEmi: #{issued.iso8601} is more than 168 hours old (G103, rej. 228)"
        end
      end

      def check_key
        id = @inf["@Id"].to_s
        issued = time(@ide["dhEmi"])
        return if id.empty? || issued.nil? || issuer_id.nil?

        add "ide/mod: #{@ide["mod"]} is not model 57 (G013, rej. 732)" unless @ide["mod"].to_s == AccessKey::MODEL.to_s
        composed = AccessKey.build(
          state: @ide["cUF"], issued_at: issued, tax_id: issuer_id, series: @ide["serie"].to_i,
          number: @ide["nCT"].to_i, numeric_code: @ide["cCT"], model: @ide["mod"].to_i,
          emission_type: @ide["tpEmis"].to_i
        )
        add "infCte/@Id: #{id} is not the key its fields compose, #{composed.id} (G014, rej. 227)" unless id == composed.id
        unless @ide["cDV"].to_s == composed.check_digit
          add "ide/cDV: #{@ide["cDV"]} is not the key's check digit, #{composed.check_digit} (G015, rej. 253)"
        end
      rescue ArgumentError
        nil
      end

      def check_locations
        check_city(@ide["cMunEnv"], @ide["UFEnv"], "ide/cMunEnv", "G178", 493, "G179", 537)
        check_city(@ide["cMunIni"], @ide["UFIni"], "ide/cMunIni", "G180", 456, "G181", 541)
        check_city(@ide["cMunFim"], @ide["UFFim"], "ide/cMunFim", "G182", 414, "G183", 542)
      end

      def check_city(code, state, path, uf_rule, uf_rej, ibge_rule, ibge_rej)
        code = code.to_s
        return if code.empty? || state.nil?

        add "#{path}: city #{code} does not belong to #{state} (#{uf_rule}, rej. #{uf_rej})" unless belongs?(code, state)
        add "#{path}: #{code} is not in the IBGE table of cities (#{ibge_rule}, rej. #{ibge_rej})" unless code == EXTERIOR_CITY || Cities.name(code)
      end

      def belongs?(city, state)
        return city == EXTERIOR_CITY if state == EXTERIOR

        code = DfeRb::States::CODES[state] or return true
        city.start_with?(code.to_s)
      end

      def check_cfop
        cfop = @ide["CFOP"].to_s
        return if cfop.empty?

        entry = Nfe::Tables.cfop(cfop)
        add "ide/CFOP: #{cfop} is not a valid transport CFOP (G049, rej. 676)" unless entry&.transport?

        uf_ini, uf_fim = @ide["UFIni"], @ide["UFFim"]
        if uf_ini && uf_fim
          expected_prefix = if uf_fim == EXTERIOR
            "7"
          elsif uf_ini == uf_fim
            "5"
          else
            "6"
          end
          add "ide/CFOP: #{cfop} must start with #{expected_prefix} for #{uf_ini} -> #{uf_fim} (G050, rej. 519)" unless cfop.start_with?(expected_prefix)
        end

        emit_uf = @emit.dig("enderEmit", "UF")
        return if nff? || emit_uf.nil? || uf_ini.nil? || uf_fim.nil? || uf_ini == EXTERIOR || uf_fim == EXTERIOR

        if emit_uf != uf_ini && !%w[5932 6932].include?(cfop)
          add "ide/CFOP: service started in #{uf_ini}, outside issuer's #{emit_uf}, requires CFOP 5932 or 6932 (G051, rej. 524)"
        elsif emit_uf == uf_ini && %w[5932 6932].include?(cfop)
          add "ide/CFOP: 5932/6932 is only for service started outside the issuer's state (G052, rej. 908)"
        end
      end

      def check_parties
        homologacao = @ide["tpAmb"].to_s == "2" && !nff?
        PARTY_CHECKS.each do |tag, spec|
          party = @inf[tag] or next
          check_party_identity(tag, party, spec[:cnpj], spec[:cpf])
          addr = party[spec[:addr]] || {}
          check_city(addr["cMun"], addr["UF"], "#{tag}/#{spec[:addr]}/cMun", spec[:city_uf][1], spec[:city_uf][0], spec[:city][1], spec[:city][0])
          if homologacao && party["xNome"] != HOMOLOGACAO_NAME
            add "#{tag}/xNome: in homologação must be #{HOMOLOGACAO_NAME.inspect} (#{spec[:hom][1]}, rej. #{spec[:hom][0]})"
          end
        end

        if (dest = @inf["dest"]) && dest["ISUF"]
          uf = dest.dig("enderDest", "UF")
          city = dest.dig("enderDest", "cMun").to_s
          in_suframa = SUFRAMA_STATES.include?(uf) || (uf == "AP" && SUFRAMA_AP_CITIES.include?(city))
          add "dest/ISUF: recipient state/city is not in SUFRAMA (G131, rej. 251)" unless in_suframa
        end

        if [SERV_INTERMEDIATE_REDISPATCH, SERV_MULTIMODAL_LINKED].include?(service_type)
          add "exped: dispatcher is required for intermediate redispatch or multimodal-linked service (G055, rej. 474)" if @inf["exped"].nil?
          add "receb: receiver is required for intermediate redispatch or multimodal-linked service (G056, rej. 475)" if @inf["receb"].nil?
        else
          add "rem: sender is required for this service type (G053, rej. 469)" if @inf["rem"].nil?
          add "dest: recipient is required for this service type (G054, rej. 470)" if @inf["dest"].nil?
        end
      end

      def check_party_identity(path, party, cnpj_spec, cpf_spec)
        cnpj, cpf = party["CNPJ"].to_s, party["CPF"].to_s
        if !cnpj.empty? && cnpj != "00000000000000" && !TaxId.valid_cnpj?(cnpj)
          add "#{path}/CNPJ: #{cnpj} is not a valid CNPJ (#{cnpj_spec[1]}, rej. #{cnpj_spec[0]})"
        end
        if !cpf.empty? && !TaxId.valid_cpf?(cpf)
          add "#{path}/CPF: #{cpf} is not a valid CPF (#{cpf_spec[1]}, rej. #{cpf_spec[0]})"
        end
      end

      def check_taker
        taker = nil
        taker_uf = nil

        if (t3 = @ide["toma3"])
          role = t3["toma"].to_s
          if (spec = TAKER_ROLES[role])
            tag, label, rule, rej = spec
            taker = @inf[tag]
            if taker.nil?
              add "ide/toma3/toma: taker is #{label}, but #{tag} is missing (#{rule}, rej. #{rej})"
            else
              taker_uf = taker.dig(PARTY_CHECKS.fetch(tag)[:addr], "UF")
            end
          end
        elsif (t4 = @ide["toma4"])
          taker = t4
          check_party_identity("ide/toma4", t4, [444, "G148"], [445, "G149"])
          addr = t4["enderToma"] || {}
          taker_uf = addr["UF"]
          check_city(addr["cMun"], taker_uf, "ide/toma4/enderToma/cMun", "G150", 447, "G151", 536)
          check_toma4_not_other_party(t4)
        end

        return unless taker

        ie = taker["IE"].to_s.strip
        case @ide["indIEToma"].to_s
        when "1"
          add "ide/indIEToma: IE is required for a contributor taker (G022, rej. 481)" if ie.empty? || ie.casecmp?("ISENTO")
        when "2"
          add "ide/indIEToma: IE must be ISENTO for an exempt taker (G023, rej. 482)" unless ie.casecmp?("ISENTO")
          if taker_uf && NO_EXEMPT_IE_STATES.include?(taker_uf)
            add "ide/indIEToma: #{taker_uf} does not accept an exempt taker, indIEToma 2 (G024, rej. 617)"
          end
        end
      end

      def check_toma4_not_other_party(t4)
        t4_id = t4["CNPJ"] || t4["CPF"]
        t4_ie = t4["IE"].to_s
        return unless t4_id

        %w[rem dest exped receb].each do |tag|
          party = @inf[tag] or next
          pid = party["CNPJ"] || party["CPF"]
          if pid == t4_id && party["IE"].to_s == t4_ie
            add "ide/toma4: taker repeats #{tag}; use toma3 instead (G156, rej. 799)"
            break
          end
        end
      end

      def check_service_and_documents
        return unless normal_or_sub? && @norm

        inf_doc = @norm["infDoc"]
        inter_or_multi = [SERV_INTERMEDIATE_REDISPATCH, SERV_MULTIMODAL_LINKED].include?(service_type)
        if !inter_or_multi && inf_doc.nil?
          add "infCTeNorm/infDoc: transported documents are required for this service type (G036, rej. 693)"
        elsif inter_or_multi && inf_doc
          add "infCTeNorm/infDoc: transported documents are forbidden for intermediate redispatch and multimodal-linked service (G037, rej. 694)"
        end

        check_inf_doc(inf_doc) if inf_doc
        check_doc_ant
        check_multimodal_linked
      end

      def check_inf_doc(inf_doc)
        nfs = Array(inf_doc["infNF"])
        nfes = Array(inf_doc["infNFe"])
        others = Array(inf_doc["infOutros"])
        total_docs = nfs.size + nfes.size + others.size
        add "infCTeNorm/infDoc: at most #{MAX_DOCUMENTS} documents allowed, got #{total_docs} (G038, rej. 601)" if total_docs > MAX_DOCUMENTS

        keys = nfes.map { |n| n["chave"].to_s }
        keys.tally.each do |k, count|
          add "infCTeNorm/infDoc/infNFe/chave: #{k} is listed #{count} times (G039, rej. 527)" if count > 1
        end
        keys.each { |k| check_referenced_key(k, path: "infCTeNorm/infDoc/infNFe/chave", model: 55, first_year: 2005, invalid_rej: 843, invalid_rule: "G040", old_rej: 930, old_rule: "G040a") }

        interstate = @ide["UFIni"] && @ide["UFFim"] && @ide["UFIni"] != @ide["UFFim"]
        if interstate
          others.each do |doc|
            if %w[59 65].include?(doc["tpDoc"].to_s)
              add "infCTeNorm/infDoc/infOutros/tpDoc: CF-e SAT (59) and NFC-e (65) are not allowed on interstate CT-e (G045, rej. 813)"
            end
          end
        end
      end

      def check_doc_ant
        doc_ant = @norm["docAnt"]
        needs_prev = [SERV_SUBCONTRACTING, SERV_REDISPATCH, SERV_INTERMEDIATE_REDISPATCH].include?(service_type)
        if needs_prev && doc_ant.nil?
          add "infCTeNorm/docAnt: previous transport documents are required for subcontracting and redispatch (G059, rej. 521)"
        elsif service_type == SERV_NORMAL && doc_ant
          add "infCTeNorm/docAnt: previous transport documents are forbidden for normal service (G060, rej. 747)"
        end
        return unless doc_ant

        all_keys = []
        taker = active_taker(@inf, @ide)
        taker_base = taker_tax_base(taker)

        Array(doc_ant["emiDocAnt"]).each do |emi|
          emi_cnpj = emi["CNPJ"]
          emi_cpf = emi["CPF"]
          emi_base = emi_cnpj ? emi_cnpj.to_s[0, 8] : emi_cpf&.to_s
          if taker_base && emi_base && taker_base != emi_base
            add "infCTeNorm/docAnt/emiDocAnt: previous document issuer must match taker's CNPJ base/CPF (G063, rej. 745)"
          end
          Array(emi["idDocAnt"]).each do |id_doc|
            Array(id_doc["idDocAntEle"]).each do |ele|
              k = ele["chCTe"].to_s
              all_keys << k
              parsed = check_referenced_key(k, path: "infCTeNorm/docAnt/emiDocAnt/idDocAnt/idDocAntEle/chCTe", model: 57, first_year: 2009, invalid_rej: 844, invalid_rule: "G065", old_rej: 931, old_rule: "G065a")
              next unless parsed

              if !nff? && (emi_cpf || (emi_cnpj && parsed.tax_id != emi_cnpj.to_s))
                add "infCTeNorm/docAnt/emiDocAnt: key #{k} issuer differs from emiDocAnt/CNPJ (G062, rej. 733)"
              end
            end
          end
        end

        all_keys.tally.each do |k, count|
          add "infCTeNorm/docAnt: key #{k} is listed #{count} times (G061, rej. 543)" if count > 1
        end
      end

      def check_multimodal_linked
        linked = @norm["infServVinc"]
        if service_type == SERV_MULTIMODAL_LINKED
          entries = Array(linked&.[]("infCTeMultimodal"))
          return add("infCTeNorm/infServVinc: reference at least one multimodal CT-e (G057, rej. 651)") if entries.empty?

          keys = entries.map { |e| e["chCTeMultimodal"].to_s }
          keys.tally.each do |k, count|
            add "infCTeNorm/infServVinc/infCTeMultimodal/chCTeMultimodal: #{k} is listed #{count} times (G070, rej. 714)" if count > 1
          end
          taker_base = taker_tax_base(active_taker(@inf, @ide))
          keys.each do |k|
            parsed = check_referenced_key(k, path: "infCTeNorm/infServVinc/infCTeMultimodal/chCTeMultimodal", model: 57, first_year: 2009, invalid_rej: 845, invalid_rule: "G071", old_rej: 932, old_rule: "G071a")
            if parsed && taker_base && parsed.tax_id[0, 8] != taker_base
              add "infCTeNorm/infServVinc/infCTeMultimodal/chCTeMultimodal: #{k} issuer CNPJ base differs from taker (G075, rej. 667)"
            end
          end
        elsif linked
          add "infCTeNorm/infServVinc: only allowed for multimodal-linked service, tpServ 4 (G058, rej. 814)"
        end
      end

      def check_values_and_icms
        vprest = @inf["vPrest"] || {}
        total = number(vprest["vTPrest"])
        receivable = number(vprest["vRec"])
        if normal_or_sub? && total > MAX_SERVICE_VALUE
          add "vPrest/vTPrest: #{total.to_s("F")} exceeds #{MAX_SERVICE_VALUE.to_s("F")} (G046, rej. 650)"
        end
        if !vprest["vTPrest"].nil? && !vprest["vRec"].nil? && receivable > total
          add "vPrest/vRec: receivable #{receivable.to_s("F")} exceeds service total #{total.to_s("F")} (G048, rej. 531)"
        end

        if normal_or_sub? && @norm && @ide["modal"].to_s != MODAL_PIPELINE && @norm.dig("infCarga", "vCarga").nil?
          add "infCTeNorm/infCarga/vCarga: cargo value is required for this modal (G027, rej. 581)"
        end

        icms = @inf.dig("imp", "ICMS")
        return unless icms.is_a?(Hash)

        check_icms_math(icms["ICMS00"], "ICMS00", "vBC", "pICMS", "vICMS")
        check_icms_math(icms["ICMS20"], "ICMS20", "vBC", "pICMS", "vICMS")
        check_icms_math(icms["ICMS90"], "ICMS90", "vBC", "pICMS", "vICMS")
        check_icms_math(icms["ICMSOutraUF"], "ICMSOutraUF", "vBCOutraUF", "pICMSOutraUF", "vICMSOutraUF")
        check_icms_math(icms["ICMS60"], "ICMS60", "vBCSTRet", "pICMSSTRet", "vICMSSTRet")
      end

      def check_icms_math(group, name, base_key, rate_key, amount_key)
        return unless group.is_a?(Hash) && group[base_key] && group[rate_key] && group[amount_key]

        expected = (number(group[base_key]) * number(group[rate_key]) / 100).round(2, half: :up)
        actual = number(group[amount_key])
        return unless (actual - expected).abs > TOLERANCE

        add "imp/ICMS/#{name}/#{amount_key}: #{actual.to_s("F")} differs from #{base_key} * #{rate_key} (#{expected.to_s("F")}) (G047, rej. 675)"
      end

      def check_ibs_cbs
        imp = @inf["imp"]
        return unless imp.is_a?(Hash)

        ibscbs = imp["IBSCBS"]
        return unless ibscbs.is_a?(Hash)

        cst = ibscbs["CST"].to_s
        class_code = ibscbs["cClassTrib"].to_s
        classification = Nfe::Tables.classification(class_code)
        add "imp/IBSCBS/cClassTrib: #{class_code} is not in the IT 2025.002 table (NT 2025.001 003, rej. 312)" unless classification
        if classification && classification.cst != cst
          add "imp/IBSCBS/cClassTrib: #{class_code} belongs to CST #{classification.cst}, not #{cst} (NT 2025.001 004, rej. 313)"
        end

        if ibscbs["indDoacao"].to_s == "1"
          taker_base = taker_tax_base(active_taker(@inf, @ide))
          emit_base = @emit["CNPJ"] ? @emit["CNPJ"].to_s[0, 8] : @emit["CPF"]&.to_s
          if taker_base && emit_base && taker_base == emit_base
            add "imp/IBSCBS/indDoacao: donation requires issuer and taker to differ (NT 2026.004, rej. 1055)"
          end
        end

        group = ibscbs["gIBSCBS"]
        if classification
          if !classification.taxed? && group
            add "imp/IBSCBS/gIBSCBS: forbidden for CST #{cst} (NT 2025.001 005, rej. 314)"
          elsif classification.taxed? && group.nil? && !%w[1 2 4].include?(@emit["CRT"]&.to_s)
            add "imp/IBSCBS/gIBSCBS: required for CST #{cst} (NT 2025.001 006, rej. 315)"
          end
        end

        check_gibscbs_math(group) if group.is_a?(Hash)

        if imp["vTotDFe"].nil?
          add "imp/vTotDFe: required whenever IBSCBS is present (NT 2025.001 §7, rej. 360)"
        else
          issued = time(@ide["dhEmi"])
          year = issued&.year || @clock.now.year
          vprest = number(@inf.dig("vPrest", "vTPrest"))
          expected_tot = if year >= 2027
            vprest + number(group&.[]("vIBS")) + number(group&.dig("gCBS", "vCBS"))
          else
            vprest
          end
          if (number(imp["vTotDFe"]) - expected_tot).abs > TOLERANCE
            add "imp/vTotDFe: #{imp["vTotDFe"]} differs from expected #{expected_tot.to_s("F")} (NT 2026.004 §4, rej. 365)"
          end
        end
      end

      def check_gibscbs_math(group)
        base = number(group["vBC"])
        uf = group["gIBSUF"] || {}
        mun = group["gIBSMun"] || {}
        cbs = group["gCBS"] || {}

        check_ibs_cbs_leg_math(uf, base, "gIBSUF", "pIBSUF", "vIBSUF", 318, 320, 390, 395)
        check_ibs_cbs_leg_math(mun, base, "gIBSMun", "pIBSMun", "vIBSMun", 323, 325, 392, 396)
        check_ibs_cbs_leg_math(cbs, base, "gCBS", "pCBS", "vCBS", 327, 329, 394, 397)

        if uf["vIBSUF"] && mun["vIBSMun"] && group["vIBS"]
          expected_ibs = number(uf["vIBSUF"]) + number(mun["vIBSMun"])
          if (number(group["vIBS"]) - expected_ibs).abs > TOLERANCE
            add "imp/IBSCBS/gIBSCBS/vIBS: #{group["vIBS"]} differs from vIBSUF + vIBSMun (#{expected_ibs.to_s("F")}) (NT 2025.001 022b, rej. 317)"
          end
        end
      end

      def check_ibs_cbs_leg_math(leg, base, name, rate_key, amount_key, amt_rej, dif_rej, eff_rej, neg_rej)
        return unless leg[rate_key]

        rate = number(leg[rate_key])
        gov_red = @ide.dig("gCompraGov", "pRedutor")
        if (red = leg["gRed"]) && red["pRedAliq"] && red["pAliqEfet"]
          expected_eff = rate * (BigDecimal(1) - number(red["pRedAliq"]) / 100)
          expected_eff *= (BigDecimal(1) - number(gov_red) / 100) if gov_red
          if (number(red["pAliqEfet"]) - expected_eff).abs > BigDecimal("0.0005")
            add "imp/IBSCBS/gIBSCBS/#{name}/gRed/pAliqEfet: #{red["pAliqEfet"]} differs from calculated #{expected_eff.round(4).to_s("F")} (rej. #{eff_rej})"
          end
        end

        applied = leg["gRed"] ? number(leg.dig("gRed", "pAliqEfet")) : rate
        gross = base * applied / 100
        if (dif = leg["gDif"]) && dif["pDif"] && dif["vDif"]
          expected_dif = (gross * number(dif["pDif"]) / 100).round(2, half: :up)
          if (number(dif["vDif"]) - expected_dif).abs > TOLERANCE
            add "imp/IBSCBS/gIBSCBS/#{name}/gDif/vDif: #{dif["vDif"]} differs from calculated #{expected_dif.to_s("F")} (rej. #{dif_rej})"
          end
        end

        deductions = number(leg.dig("gDif", "vDif")) + number(leg.dig("gDevTrib", "vDevTrib"))
        if deductions - gross > TOLERANCE
          add "imp/IBSCBS/gIBSCBS/#{name}/#{amount_key}: deferral and tax return exceed gross tax (rej. #{neg_rej})"
        end
        return unless leg[amount_key]

        expected = (gross - deductions).round(2, half: :up)
        if (number(leg[amount_key]) - expected).abs > TOLERANCE
          add "imp/IBSCBS/gIBSCBS/#{name}/#{amount_key}: #{leg[amount_key]} differs from calculated #{expected.to_s("F")} (rej. #{amt_rej})"
        end
      end

      def check_modals
        return unless normal_or_sub? && @norm

        modal = @ide["modal"].to_s
        group = @norm["infModal"] || {}
        if modal == MODAL_WATER && [SERV_INTERMEDIATE_REDISPATCH, SERV_MULTIMODAL_LINKED].include?(service_type)
          if Array(group.dig("aquav", "detCont")).empty?
            add "infCTeNorm/infModal/aquav/detCont: containers are required for water modal intermediate redispatch or multimodal-linked service (G028, rej. 526)"
          end
        elsif modal == MODAL_RAIL && (ferrov = group["ferrov"])
          check_rail(ferrov)
        end
      end

      def check_rail(ferrov)
        mut = ferrov["trafMut"]
        if ferrov["tpTraf"].to_s == "1" && mut.nil?
          add "infCTeNorm/infModal/ferrov/trafMut: mutual traffic group is required when tpTraf is 1 (G029, rej. 582)"
        end
        return unless mut

        if mut["respFat"].to_s == "1" && mut["ferrEmi"].to_s != "1"
          add "infCTeNorm/infModal/ferrov/trafMut/ferrEmi: must be 1 when respFat is 1 (G030, rej. 583)"
        elsif mut["respFat"].to_s == "2" && mut["chCTeFerroOrigem"].to_s.empty?
          add "infCTeNorm/infModal/ferrov/trafMut/chCTeFerroOrigem: origin railway CT-e is required when respFat is 2 (G031, rej. 584)"
        end
        return unless mut["chCTeFerroOrigem"]

        check_referenced_key(mut["chCTeFerroOrigem"].to_s, path: "infCTeNorm/infModal/ferrov/trafMut/chCTeFerroOrigem", model: 57, first_year: 2009, invalid_rej: 842, invalid_rule: "G032")
      end

      def check_substitution_and_complement
        if cte_type == SUBSTITUTION
          add "ide/tpEmis: a substitution CT-e must use normal emission, tpEmis 1 (G076, rej. 503)" unless emission_type == EMIS_NORMAL
          sub = @norm&.[]("infCteSub")
          if sub.nil?
            add "infCTeNorm/infCteSub: required for a substitution CT-e (G077, rej. 505)"
          else
            check_referenced_key(sub["chCte"].to_s, path: "infCTeNorm/infCteSub/chCte", model: 57, first_year: 2009, invalid_rej: 847, invalid_rule: "G078")
          end
        elsif cte_type == COMPLEMENTARY
          entries = Array(@inf["infCteComp"])
          keys = entries.map { |e| e["chCTe"].to_s }
          keys.tally.each do |k, count|
            add "infCteComp/chCTe: #{k} is listed #{count} times (G177, rej. 907)" if count > 1
          end
          max_months = [MODAL_RAIL, MODAL_WATER].include?(@ide["modal"].to_s) ? COMPLEMENT_EXTENDED_MONTHS : COMPLEMENT_MONTHS
          keys.each do |k|
            parsed = check_referenced_key(k, path: "infCteComp/chCTe", model: 57, first_year: 2009, invalid_rej: 849, invalid_rule: "G161", old_rej: 933, old_rule: "G161a", max_months: max_months)
            if parsed && @emit["CNPJ"] && parsed.tax_id != @emit["CNPJ"].to_s
              add "infCteComp/chCTe: #{k} was issued by #{parsed.tax_id}, not #{@emit["CNPJ"]} (G160, rej. 269)"
            end
          end
        end
      end

      def check_globalized
        globalized = @ide["indGlobalizado"].to_s == "1"
        unless globalized
          if @inf.dig("rem", "xNome") == "DIVERSOS" || @inf.dig("dest", "xNome") == "DIVERSOS"
            add "rem/dest xNome: DIVERSOS requires indGlobalizado 1 (G208, rej. 730)"
          end
          return
        end

        add "ide/indGlobalizado: globalized CT-e cannot cross states (G197, rej. 743)" if @ide["UFIni"] != @ide["UFFim"]
        toma = @ide.dig("toma3", "toma")&.to_s
        unless %w[0 3].include?(toma)
          return add("ide/indGlobalizado: taker must be sender (0) or recipient (3) (G198, rej. 722)")
        end

        if normal_or_sub? && @norm
          nfes = Array(@norm.dig("infDoc", "infNFe"))
          if nfes.empty? || Array(@norm.dig("infDoc", "infNF")).any? || Array(@norm.dig("infDoc", "infOutros")).any?
            add "infCTeNorm/infDoc: globalized CT-e must list NF-e only (G199, rej. 723)"
          elsif toma == "3"
            emitters = nfes.filter_map { |n| DfeRb::AccessKey.valid?(n["chave"]) ? DfeRb::AccessKey.parse(n["chave"]).tax_id : nil }.uniq
            add "infCTeNorm/infDoc/infNFe: globalized CT-e for recipient taker requires at least 5 distinct NF-e issuers (G200, rej. 724)" if emitters.size < 5
          elsif toma == "0"
            emitters = nfes.filter_map { |n| DfeRb::AccessKey.valid?(n["chave"]) ? DfeRb::AccessKey.parse(n["chave"]).tax_id : nil }.uniq
            add "infCTeNorm/infDoc/infNFe: globalized CT-e for sender taker requires all NF-e from one issuer (G201, rej. 744)" if emitters.size > 1
            add "infCTeNorm/infDoc/infNFe: globalized CT-e for sender taker requires at least 5 NF-e (G206, rej. 737)" if nfes.size < 5
          end
        end

        if toma == "3" && @emit["CNPJ"] && @inf.dig("rem", "CNPJ") != @emit["CNPJ"]
          add "rem/CNPJ: globalized CT-e with recipient taker uses issuer's CNPJ on rem (G204, rej. 727)"
        elsif toma == "0" && @emit["CNPJ"] && @inf.dig("dest", "CNPJ") != @emit["CNPJ"]
          add "dest/CNPJ: globalized CT-e with sender taker uses issuer's CNPJ on dest (G205, rej. 728)"
        end
        return unless @ide["tpAmb"].to_s == "1"

        if toma == "3" && @inf.dig("rem", "xNome") != "DIVERSOS"
          add "rem/xNome: globalized CT-e with recipient taker must be DIVERSOS in production (G202, rej. 725)"
        elsif toma == "0" && @inf.dig("dest", "xNome") != "DIVERSOS"
          add "dest/xNome: globalized CT-e with sender taker must be DIVERSOS in production (G203, rej. 726)"
        end
      end

      def check_authorized
        entries = Array(@inf["autXML"])
        party_ids = %w[rem dest exped receb].filter_map { |t| @inf.dig(t, "CNPJ") || @inf.dig(t, "CPF") }
        t4_id = @ide.dig("toma4", "CNPJ") || @ide.dig("toma4", "CPF")
        party_ids << t4_id if t4_id

        entries.each do |entry|
          cnpj, cpf = entry["CNPJ"], entry["CPF"]
          add "autXML/CNPJ: #{cnpj} is not a valid CNPJ (G193, rej. 699)" if cnpj && !TaxId.valid_cnpj?(cnpj.to_s)
          add "autXML/CPF: #{cpf} is not a valid CPF (G194, rej. 700)" if cpf && !TaxId.valid_cpf?(cpf.to_s)
          id = cnpj || cpf
          add "autXML: #{id} is already a party on the CT-e (G196, rej. 828)" if id && party_ids.include?(id)
        end
        entries.map { |entry| entry["CNPJ"] || entry["CPF"] }.compact.tally.each do |id, count|
          add "autXML: #{id} is listed #{count} times (G195, rej. 715)" if count > 1
        end
      end

      def check_payment_links
        entries = Array(@inf.dig("pgtoVinc", "pgto"))
        entries.each do |entry|
          npag = entry["@nPag"]
          receiver = entry["CNPJReceb"].to_s
          if !receiver.empty? && !TaxId.valid_cnpj?(receiver)
            add "pgtoVinc/pgto/CNPJReceb: #{receiver} is not a valid CNPJ [nPag: #{npag}] (NT 2026.001 L11, rej. 1001)"
          end
          method = entry["tpMeioPgto"].to_s
          if !method.empty? && Nfe::Tables.payment_link_method(method).nil?
            add "pgtoVinc/pgto/tpMeioPgto: #{method} is not a valid payment link method [nPag: #{npag}] (NT 2026.001 L12, rej. 1003)"
          end
        end
      end

      def check_qr_code
        return add("infCTeSupl/qrCodCTe: the QR code URL is required (G212, rej. 850)") if @qr_code.to_s.empty?

        parts = QrCode.parse(@qr_code)
        return add("infCTeSupl/qrCodCTe: #{@qr_code} has no chCTe and tpAmb (G214, rej. 852)") unless parts

        state = @emit.dig("enderEmit", "UF")
        if state && DfeRb::States::CODES.key?(state)
          expected_url = @qr_code_base_url || QrCode.base_url_for(state: state, environment: @ide["tpAmb"])
          unless same_qr_address?(parts[:address], expected_url)
            add "infCTeSupl/qrCodCTe: the address must be #{expected_url} (G213, rej. 851)"
          end
        end

        key = @inf["@Id"].to_s.delete_prefix("CTe")
        add "infCTeSupl/qrCodCTe: chCTe differs from the waybill's key, #{key} (G214, rej. 852)" unless parts[:key] == key

        case emission_type
        when EMIS_OFFLINE, EMIS_EPEC
          if parts[:sign].nil?
            add "infCTeSupl/qrCodCTe: a CT-e issued in offline or EPEC contingency signs its key in `sign` (G215, rej. 853)"
          elsif @signer && !QrCode.signed_by?(key, parts[:sign], @signer)
            add "infCTeSupl/qrCodCTe: `sign` is not the key signed with the waybill's certificate (G217, rej. 855)"
          end
        when EMIS_NORMAL, EMIS_SVC_RS, EMIS_SVC_SP
          add "infCTeSupl/qrCodCTe: `sign` is for offline or EPEC contingency only (G216, rej. 854)" if parts[:sign]
        end
      end

      def same_qr_address?(actual, expected)
        actual.casecmp?(expected) || actual.casecmp?(expected.sub(/\Ahttps:/i, "http:")) || actual.casecmp?(expected.sub(/\Ahttp:/i, "https:"))
      end

      def check_technical_contact
        contact = @inf["infRespTec"] or return

        cnpj = contact["CNPJ"].to_s
        add "infRespTec/CNPJ: #{cnpj} is not a valid CNPJ (G210, rej. 836)" unless TaxId.valid_cnpj?(cnpj)
        add "infRespTec/idCSRT: required with a CSRT (G211, rej. 868)" if @csrt && contact["idCSRT"].nil?
      end

      def check_referenced_key(value, path:, model:, first_year:, invalid_rej:, invalid_rule:, old_rej: nil, old_rule: nil, max_months: MONTHS_KEPT)
        unless DfeRb::AccessKey.valid?(value)
          add "#{path}: #{value} is not a valid access key (#{invalid_rule}, rej. #{invalid_rej})"
          return nil
        end

        key = DfeRb::AccessKey.parse(value)
        add "#{path}: #{value} is model #{key.model}, not #{model} (#{invalid_rule}, rej. #{invalid_rej})" unless key.model == model
        year, month = 2000 + key.year_month[0, 2].to_i, key.year_month[2, 2].to_i
        unless (first_year..@clock.now.year).cover?(year) && (1..12).cover?(month)
          add "#{path}: #{value} has an impossible year and month, #{key.year_month} (#{invalid_rule}, rej. #{invalid_rej})"
        end
        add "#{path}: #{value} has document number zero (#{invalid_rule}, rej. #{invalid_rej})" if key.number.zero?
        add "#{path}: #{value} has an unknown state, #{key.state_code} (#{invalid_rule}, rej. #{invalid_rej})" if key.state.nil?
        add "#{path}: #{value} has emission type zero (#{invalid_rule}, rej. #{invalid_rej})" if key.emission_type.zero?
        person = key.tax_id.start_with?("000") && TaxId.valid_cpf?(key.tax_id[3..])
        add "#{path}: #{value} has an invalid issuer, #{key.tax_id} (#{invalid_rule}, rej. #{invalid_rej})" unless person || TaxId.valid_cnpj?(key.tax_id)

        if old_rej
          now = @clock.now
          if (now.year * 12 + now.month) - (year * 12 + month) > max_months
            add "#{path}: #{value} is from #{format("%02d/%d", month, year)}, more than #{max_months} months ago (#{old_rule}, rej. #{old_rej})"
          end
        end
        key
      end

      def active_taker(inf, ide)
        return ide["toma4"] if ide["toma4"].is_a?(Hash)

        role = ide.dig("toma3", "toma")&.to_s
        tag = Resolver::TAKER_PARTIES[role]
        tag && inf[tag]
      end

      def taker_tax_base(taker)
        return unless taker.is_a?(Hash)

        taker["CNPJ"] ? taker["CNPJ"].to_s[0, 8] : taker["CPF"]&.to_s
      end

      def number(value)
        BigDecimal(value.to_s)
      rescue ArgumentError
        BigDecimal(0)
      end

      def time(value)
        return value.to_time if value.is_a?(DateTime)
        return value if value.is_a?(Time)

        Time.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end
    end
  end
end
