require "bigdecimal"
require "date"

module DfeRb
  module Mdfe
    # The MDF-e rules that can be checked without SEFAZ's databases (MOC 3.00b Anexo I §2.2,
    # NT 2025.001, NT 2026.001), over a resolved infMDFe. Each message names the field, the
    # rule and the rejection SEFAZ would answer with. What depends on a register (the IE, the
    # RNTRC, a duplicate number, a manifest left open, whether a document exists) is SEFAZ's.
    class Validator
      TOLERANCE = BigDecimal("0.01")
      ROAD = "1"
      AIR = "2"
      WATER = "3"
      CARRIER = "1"
      OWN_CARGO = "2"
      GLOBALIZED = "3"
      NORMAL = "1"
      CONTINGENCY = "2"
      EXTERIOR = "EX"
      EXTERIOR_CITY = "9999999"
      PERSON_SERIES = AccessKey::PERSON_SERIES
      # tpEmis of a document printed on security paper (FS-DA), whose second bar code the
      # manifest must carry (F35, F41).
      FS_DA = 5
      # Documents a manifest lists, with the model and first year of each one's key, and the
      # rejections of a bad key, of one too old and of one repeated.
      DOCUMENTS = {
        "infCTe" => ["chCTe", [57], 2008, 601, 518, 668], "infNFe" => ["chNFe", [55], 2006, 604, 519, 669],
        "infMDFeTransp" => ["chMDFe", [58], 2012, 649, 520, nil]
      }.freeze
      # How old a listed document's key may be, by its year and month (NT 2024.001).
      MONTHS_KEPT = 6
      # When the CIOT became required, per tpAmb (NT 2026.001).
      CIOT_SINCE = {"2" => Time.new(2026, 9, 21, 0, 0, 0, "-03:00"), "1" => Time.new(2026, 11, 23, 0, 0, 0, "-03:00")}.freeze
      # The states each one borders, which is what a road route can cross in order (F90).
      BORDERS = {
        "AC" => %w[AM RO], "AL" => %w[BA PE SE], "AM" => %w[AC MT PA RO RR], "AP" => %w[PA],
        "BA" => %w[AL ES GO MG PE PI SE TO], "CE" => %w[PB PE PI RN], "DF" => %w[GO MG], "ES" => %w[BA MG RJ],
        "GO" => %w[BA DF MG MS MT TO], "MA" => %w[PA PI TO], "MG" => %w[BA DF ES GO MS RJ SP],
        "MS" => %w[GO MG MT PR SP], "MT" => %w[AM GO MS PA RO TO], "PA" => %w[AM AP MA MT RR TO],
        "PB" => %w[CE PE RN], "PE" => %w[AL BA CE PB PI], "PI" => %w[BA CE MA PE TO], "PR" => %w[MS SC SP],
        "RJ" => %w[ES MG SP], "RN" => %w[CE PB], "RO" => %w[AC AM MT], "RR" => %w[AM PA], "RS" => %w[SC],
        "SC" => %w[PR RS], "SE" => %w[AL BA], "SP" => %w[MG MS PR RJ], "TO" => %w[BA GO MA MT PA PI]
      }.freeze

      # qr_code: the URL that goes in infMDFeSupl. csrt: the CSRT the manifest was built with.
      # signer: the X509 certificate that signs the manifest, to check a QR code that came
      # with the XML.
      def initialize(infmdfe, qr_code: nil, clock: Time, csrt: nil, signer: nil)
        @inf = infmdfe
        @ide = infmdfe["ide"] || {}
        @emit = infmdfe["emit"] || {}
        @qr_code = qr_code
        @clock = clock
        @csrt = csrt
        @signer = signer
        @issues = []
      end

      # Messages for each rule the manifest breaks.
      def issues
        @issues = []
        check_issuer
        check_identification
        check_key
        check_cities
        check_later_loading
        check_documents
        check_road if road?
        check_authorized
        check_qr_code
        check_technical_contact
        @issues
      end

      private

      def add(message) = @issues << message

      def road? = @ide["modal"].to_s == ROAD

      def issuer_type = @ide["tpEmit"].to_s

      def later_loading? = @ide["indCarregaPosterior"].to_s == "1"

      def interstate? = @ide["UFIni"] && @ide["UFFim"] && @ide["UFIni"] != @ide["UFFim"]

      def rodo = @inf.dig("infModal", "rodo") || {}

      def antt = rodo["infANTT"] || {}

      # A carrier for hire, or an own-cargo issuer who told the kind of carrier hauling it:
      # the manifests the ANTT rules are about (F52...).
      def hired? = [CARRIER, GLOBALIZED].include?(issuer_type) || (issuer_type == OWN_CARGO && !@ide["tpTransp"].nil?)

      def unloading = Array(@inf.dig("infDoc", "infMunDescarga"))

      def issuer_id = @emit["CNPJ"] || @emit["CPF"]

      def check_issuer
        cnpj, cpf = @emit.values_at("CNPJ", "CPF")
        add "emit/CNPJ: #{cnpj} is not a valid CNPJ (F67, rej. 207)" if cnpj && !TaxId.valid_cnpj?(cnpj.to_s)
        add "emit/CPF: #{cpf} is not a valid CPF (F68, rej. 210)" if cpf && !TaxId.valid_cpf?(cpf.to_s)
        add "emit: give the issuer's CNPJ or CPF" if cnpj.nil? && cpf.nil?

        series = @ide["serie"].to_i
        if cnpj && PERSON_SERIES.cover?(series)
          add "ide/serie: series #{PERSON_SERIES.min} to #{PERSON_SERIES.max} are kept for issuers with a CPF (F69, rej. 232)"
        elsif cpf && !PERSON_SERIES.cover?(series)
          add "ide/serie: an issuer with a CPF uses series #{PERSON_SERIES.min} to #{PERSON_SERIES.max} (F70, rej. 233)"
        end
        add "ide/tpEmit: an issuer with a CPF can only carry its own cargo, tpEmit 2 (F71, rej. 234)" if cpf && issuer_type != OWN_CARGO
        add "emit/IE: the issuer's state registration is required (F72, rej. 229)" if @emit["IE"].to_s.delete("0").empty?

        address = @emit["enderEmit"] || {}
        city, state = address["cMun"].to_s, address["UF"]
        return if city.empty? || state.nil?

        add "emit/enderEmit/cMun: city #{city} does not belong to #{state} (F77, rej. 613)" unless belongs?(city, state)
        add "emit/enderEmit/cMun: #{city} is not in the IBGE table of cities (F78, rej. 407)" unless Cities.name(city)
        if @ide["cUF"] && States::CODES[state] && @ide["cUF"].to_s != States.code(state)
          add "ide/cUF: #{@ide["cUF"]} is not the issuer's state, #{state} (F02, rej. 247)"
        end
      end

      def check_identification
        add "ide/nMDF: the manifest number is required" if @ide["nMDF"].nil?
        add "ide/tpEmit: the issuer type is required (:carrier, :own_cargo or :globalized_cte)" if issuer_type.empty?
        add "infModal: fill in one modal (road, air, water or rail)" if @ide["modal"].nil?
        if issuer_type == GLOBALIZED && (interstate? || [@ide["UFIni"], @ide["UFFim"]].include?(EXTERIOR))
          add "ide/tpEmit: a globalized CT-e manifest (tpEmit 3) can't cross states or borders (F17, rej. 541)"
        end
        add "infSolicNFF: only for the Nota Fiscal Fácil, tpEmis 3 (F123, rej. 902)" if @inf["infSolicNFF"] && @ide["tpEmis"].to_s != "3"

        issued = time(@ide["dhEmi"]) or return
        now = @clock.now
        add "ide/dhEmi: #{issued.iso8601} is in the future (F79, rej. 212)" if issued > now + 300
        if @ide["tpEmis"].to_s == NORMAL && issued < now - 86_400
          add "ide/dhEmi: #{issued.iso8601} is more than 24 hours old; a normal emission is transmitted at once (F80, rej. 228)"
        end
      end

      # The Id is the key its fields compose, check digit included (F03, F05).
      def check_key
        id = @inf["@Id"].to_s
        issued = time(@ide["dhEmi"])
        return if id.empty? || issued.nil? || issuer_id.nil?

        composed = AccessKey.build(state: @ide["cUF"], issued_at: issued, tax_id: issuer_id, series: @ide["serie"].to_i,
          number: @ide["nMDF"].to_i, numeric_code: @ide["cMDF"], model: @ide["mod"].to_i, emission_type: @ide["tpEmis"].to_i)
        add "infMDFe/@Id: #{id} is not the key its fields compose, #{composed} (F03, rej. 227)" unless id == composed.id
        unless @ide["cDV"].to_s == composed.check_digit
          add "ide/cDV: #{@ide["cDV"]} is not the key's check digit, #{composed.check_digit} (F05, rej. 253)"
        end
      rescue ArgumentError
        nil
      end

      def check_cities
        loading = Array(@ide["infMunCarrega"]).map { |city| city["cMunCarrega"].to_s }
        check_city_list(loading, @ide["UFIni"], "ide/infMunCarrega/cMunCarrega", "ide/UFIni", [456, 405, 685], %w[F08 F09 F10])
        check_city_list(unloading.map { |city| city["cMunDescarga"].to_s }, @ide["UFFim"],
          "infDoc/infMunDescarga/cMunDescarga", "ide/UFFim", [612, 406, 680], %w[F11 F12 F13])
        add "infDoc: at least one unloading city is required" if unloading.empty?
      end

      def check_city_list(codes, state, path, state_path, rejections, rules)
        diverges, unknown, duplicate = rejections
        codes.each do |code|
          add "#{path}: city #{code} does not belong to #{state_path} #{state} (#{rules[0]}, rej. #{diverges})" if state && !belongs?(code, state)
          add "#{path}: #{code} is not in the IBGE table of cities (#{rules[1]}, rej. #{unknown})" unless code == EXTERIOR_CITY || Cities.name(code)
        end
        codes.tally.each { |code, count| add "#{path}: city #{code} is listed #{count} times (#{rules[2]}, rej. #{duplicate})" if count > 1 }
      end

      def belongs?(city, state)
        return city == EXTERIOR_CITY if state == EXTERIOR

        code = States::CODES[state] or return true
        city.start_with?(code.to_s)
      end

      def check_later_loading
        return unless later_loading?

        loading = Array(@ide["infMunCarrega"]).map { |city| city["cMunCarrega"] }
        unloading_codes = unloading.map { |city| city["cMunDescarga"] }
        unless loading.size == 1 && unloading_codes == loading
          add "ide/indCarregaPosterior: a manifest loaded later has one loading city, which is also its only unloading city (F21, rej. 703)"
        end
        if interstate? || @ide["UFIni"] == EXTERIOR
          add "ide/indCarregaPosterior: a manifest loaded later can't cross states or borders (F22, rej. 704)"
        end
        add "ide/indCarregaPosterior: only the road modal can be loaded later (F23, rej. 705)" unless road?
        add "ide/indCarregaPosterior: only an own-cargo issuer, tpEmit 2, can load later (F24, rej. 707)" unless issuer_type == OWN_CARGO
      end

      def check_documents
        counts = Hash.new(0)
        keys = Hash.new { |hash, group| hash[group] = [] }
        unloading.each do |city|
          code = city["cMunDescarga"]
          given = DOCUMENTS.keys.sum { |group| Array(city[group]).size }
          if later_loading?
            add "infDoc/infMunDescarga #{code}: a manifest loaded later lists no documents; add them with the Inclusão de DF-e event (F27, rej. 706)" if given.positive?
          elsif given.zero?
            add "infDoc/infMunDescarga #{code}: no document unloads here; list its CT-e, NF-e or MDF-e (F26, rej. 616)"
          end

          DOCUMENTS.each do |group, (tag, *)|
            Array(city[group]).each do |document|
              counts[group] += 1
              keys[group] << [interstate? ? nil : code, document[tag].to_s]
              check_document(group, document)
            end
          end
        end

        check_duplicates(keys)
        check_document_kinds(counts)
        check_totals(counts)
      end

      def check_document(group, document)
        tag, models, first_year, rejection, too_old, = DOCUMENTS.fetch(group)
        value = document[tag].to_s
        path = "infDoc/infMunDescarga/#{group}/#{tag}"
        unless DfeRb::AccessKey.valid?(value)
          return add "#{path}: #{value} is not a valid access key (check digit or format, rej. #{rejection})"
        end

        key = DfeRb::AccessKey.parse(value)
        add "#{path}: #{value} is of model #{key.model}, not #{models.join(" or ")} (rej. #{rejection})" unless models.include?(key.model)
        year, month = 2000 + key.year_month[0, 2].to_i, key.year_month[2, 2].to_i
        unless (first_year..@clock.now.year).cover?(year) && (1..12).cover?(month)
          add "#{path}: #{value} has an impossible year and month, #{key.year_month} (rej. #{rejection})"
        end
        add "#{path}: #{value} has document number zero (rej. #{rejection})" if key.number.zero?
        add "#{path}: #{value} has an unknown state, #{key.state_code} (rej. #{rejection})" if key.state.nil?
        add "#{path}: #{value} has emission type zero (rej. #{rejection})" if key.emission_type.zero?
        person = key.tax_id.start_with?("000") && TaxId.valid_cpf?(key.tax_id[3..])
        add "#{path}: #{value} has an invalid issuer, #{key.tax_id} (rej. #{rejection})" unless person || TaxId.valid_cnpj?(key.tax_id)
        now = @clock.now
        if (now.year * 12 + now.month) - (year * 12 + month) > MONTHS_KEPT
          add "#{path}: #{value} is from #{format("%02d/%d", month, year)}, more than #{MONTHS_KEPT} months ago (NT 2024.001, rej. #{too_old})"
        end
        check_second_barcode(group, path, key, document) unless group == "infMDFeTransp"
        if group == "infCTe" && document["infEntregaParcial"] && @ide["modal"].to_s != AIR
          add "infDoc/infMunDescarga/infCTe/infEntregaParcial: partial delivery is for the air modal only (F34, rej. 702) [chCTe: #{value}]"
        end
      end

      def check_second_barcode(group, path, key, document)
        required, forbidden = (group == "infCTe") ? [602, 603] : [606, 607]
        if key.emission_type == FS_DA && document["SegCodBarra"].nil?
          add "#{path}: #{key} was issued on FS-DA paper; its second bar code (SegCodBarra) is required (rej. #{required})"
        elsif key.emission_type != FS_DA && document["SegCodBarra"]
          add "#{path}: #{key} was not issued on FS-DA paper; it takes no second bar code (rej. #{forbidden})"
        end
      end

      # A key may not repeat in the manifest when it crosses states, nor in one unloading
      # city when it doesn't (F28, F29).
      def check_duplicates(keys)
        keys.each do |group, entries|
          tag, *, rejection = DOCUMENTS.fetch(group)
          next unless rejection

          entries.tally.each do |(_city, key), count|
            add "infDoc/infMunDescarga/#{group}/#{tag}: #{key} is listed #{count} times (rej. #{rejection})" if count > 1
          end
        end
      end

      def check_document_kinds(counts)
        if issuer_type == CARRIER && counts["infNFe"].positive?
          add "infDoc: a carrier (tpEmit 1) lists CT-e, not NF-e (F14, rej. 638)"
        elsif issuer_type == OWN_CARGO && counts["infCTe"].positive?
          add "infDoc: an own-cargo issuer (tpEmit 2) lists NF-e, not CT-e (F15, rej. 639)"
        elsif issuer_type == GLOBALIZED && counts["infCTe"].positive?
          add "infDoc: an issuer of a globalized CT-e (tpEmit 3) lists NF-e, not CT-e (F16, rej. 540)"
        end
        return unless counts["infMDFeTransp"].positive?

        add "infDoc: only a water manifest can list other MDF-e (F43, rej. 647)" unless @ide["modal"].to_s == WATER
        unless ([@ide["UFIni"], @ide["UFFim"]] & %w[AM AP]).any?
          add "infDoc: other MDF-e can be listed only when the trip starts or ends in AM or AP (F44, rej. 648)"
        end
      end

      def check_totals(counts)
        tot = @inf["tot"] || {}
        {"infCTe" => "qCTe", "infNFe" => "qNFe", "infMDFeTransp" => "qMDFe"}.each do |group, counter|
          next if tot[counter].to_i == counts[group]

          add "tot/#{counter}: #{tot[counter].inspect} differs from the #{counts[group]} listed in infDoc (F51, rej. 667)"
        end
        add "tot/vCarga: the cargo's value is required" if tot["vCarga"].nil?
        add "tot/qCarga: the cargo's gross weight is required" if tot["qCarga"].nil?
      end

      def check_road
        vehicle = rodo["veicTracao"] || {}
        check_carrier_type(vehicle["prop"])
        check_owners(vehicle)
        check_drivers(vehicle)
        check_contractors(vehicle["prop"])
        check_antt_parties
        check_toll_vouchers
        check_route
        return unless hired?

        check_insurance
        check_full_load
        check_ciot
        Array(antt["infPag"]).each_with_index { |payment, index| check_payment(payment, "infModal/rodo/infANTT/infPag[#{index + 1}]") }
        if interstate? && issuer_type != OWN_CARGO && antt["RNTRC"].nil?
          add "infModal/rodo/infANTT/RNTRC: a carrier crossing states gives its RNTRC (F108, rej. 688)"
        end
      end

      def check_carrier_type(owner)
        kind = @ide["tpTransp"]&.to_s
        if owner.nil?
          add "ide/tpTransp: not given unless the traction vehicle has an owner (F20, rej. 745)" if kind
        elsif owner["CPF"]
          add "ide/tpTransp: must be TAC (2) when the traction vehicle's owner has a CPF (F18, rej. 743)" unless kind == "2"
        elsif owner["CNPJ"]
          add "ide/tpTransp: must be ETC (1) or CTC (3) when the traction vehicle's owner has a CNPJ (F19, rej. 744)" unless %w[1 3].include?(kind)
        end
      end

      def check_owners(vehicle)
        owner = vehicle["prop"]
        check_tax_id("infModal/rodo/veicTracao/prop", owner, "F103, rej. 718") if owner
        if owner && issuer_id && [owner["CNPJ"], owner["CPF"]].include?(issuer_id)
          add "infModal/rodo/veicTracao/prop: leave the owner out when the vehicle is the issuer's own (F64, rej. 740)"
        end
        Array(rodo["veicReboque"]).each_with_index do |trailer, index|
          check_tax_id("infModal/rodo/veicReboque[#{index + 1}]/prop", trailer["prop"], "F104, rej. 719") if trailer["prop"]
        end
      end

      def check_drivers(vehicle)
        drivers = Array(vehicle["condutor"]).map { |driver| driver["CPF"].to_s }
        add "infModal/rodo/veicTracao/condutor: at least one driver is required" if drivers.empty?
        drivers.each { |cpf| add "infModal/rodo/veicTracao/condutor/CPF: #{cpf} is not a valid CPF (F100, rej. 645)" unless TaxId.valid_cpf?(cpf) }
        drivers.tally.each { |cpf, count| add "infModal/rodo/veicTracao/condutor/CPF: #{cpf} is listed #{count} times (F99, rej. 577)" if count > 1 }
      end

      def check_contractors(owner)
        contractors = Array(antt["infContratante"])
        ids = contractors.map { |contractor| contractor["CNPJ"] || contractor["CPF"] || contractor["idEstrangeiro"] }
        ids.compact.tally.each do |id, count|
          add "infModal/rodo/infANTT/infContratante: #{id} is listed #{count} times (F66, rej. 742)" if count > 1
        end
        return unless owner && issuer_id && ids != [issuer_id]

        add "infModal/rodo/infANTT/infContratante: with an owner on the traction vehicle, the only contractor is the issuer, #{issuer_id} (F65, rej. 741)"
      end

      def check_antt_parties
        Array(antt["infCIOT"]).each { |ciot| check_tax_id("infModal/rodo/infANTT/infCIOT", ciot, "F101, rej. 716") }
        Array(antt["infContratante"]).each { |party| check_tax_id("infModal/rodo/infANTT/infContratante", party, "F102, rej. 717") }
        return unless hired?

        given = Array(antt["infCIOT"]).any? || Array(antt.dig("valePed", "disp")).any? { |device| device["CNPJPg"] || device["CPFPg"] }
        return if given || Array(antt["infContratante"]).any?

        add "infModal/rodo/infANTT/infContratante: name who contracted the transport (or the CIOT, or who paid the toll voucher) (F94, rej. 578)"
      end

      def check_toll_vouchers
        vouchers = antt["valePed"] or return

        add "infModal/rodo/infANTT/valePed/categCombVeic: the vehicle category is required with a toll voucher (F95, rej. 731)" if vouchers["categCombVeic"].nil?
        Array(vouchers["disp"]).each do |device|
          supplier = device["CNPJForn"].to_s
          add "infModal/rodo/infANTT/valePed/disp/CNPJForn: #{supplier} is not a valid CNPJ (F96, rej. 732)" unless TaxId.valid_cnpj?(supplier)
          check_tax_id("infModal/rodo/infANTT/valePed/disp", device, "F98, rej. 734", cnpj: "CNPJPg", cpf: "CPFPg")
        end
      end

      # The states crossed, in order: each one borders the one before it (F90).
      def check_route
        first, last = @ide["UFIni"], @ide["UFFim"]
        return unless BORDERS.key?(first) && BORDERS.key?(last)

        states = [first, *Array(@ide["infPercurso"]).map { |entry| entry["UFPer"] }, last]
        return if states.size == 2 && first == last

        gap = states.each_cons(2).find { |from, to| from != to && !BORDERS.fetch(from, []).include?(to) }
        return unless gap

        add "ide/infPercurso: #{gap.join(" and ")} share no border; list every state crossed from #{first} to #{last}, in order, with `route` (F90, rej. 663)"
      end

      def check_insurance
        return if issuer_type == OWN_CARGO

        policies = Array(@inf["seg"])
        return add "seg: a carrier's road manifest declares the cargo's insurance (F91, rej. 698)" if policies.empty?

        policies.each_with_index do |policy, index|
          path = "seg[#{index + 1}]"
          missing = []
          missing << "infSeg/xSeg" if policy.dig("infSeg", "xSeg").to_s.empty?
          missing << "infSeg/CNPJ" if policy.dig("infSeg", "CNPJ").to_s.empty?
          missing << "nApol" if policy["nApol"].to_s.empty?
          missing << "nAver" if Array(policy["nAver"]).empty?
          add "#{path}: the insurance lacks #{missing.join(", ")} (F92, rej. 699)" unless missing.empty?

          responsible = policy["infResp"] || {}
          if responsible["respSeg"].to_s == "2" && responsible["CNPJ"].nil? && responsible["CPF"].nil?
            add "#{path}/infResp: give the CNPJ or CPF of the contractor responsible for the insurance (F93, rej. 542)"
          end
        end
      end

      # A manifest of one document is a full load (carga lotação): the ANTT wants where it
      # loads and unloads, the product's NCM and how the freight is paid.
      def check_full_load
        product = @inf["prodPred"]
        add "prodPred: the main product is required on a road manifest (F54, rej. 725)" if product.nil?
        return unless unloading.sum { |city| DOCUMENTS.keys.sum { |group| Array(city[group]).size } } == 1

        add "prodPred/infLotacao: a manifest of a single document says where the full load is loaded and unloaded (F55, rej. 726)" if product&.dig("infLotacao").nil?
        add "prodPred/NCM: a manifest of a single document gives the main product's NCM (F55a, rej. 301)" if product && product["NCM"].nil?
        add "infModal/rodo/infANTT/infPag: a manifest of a single document says how the freight is paid (F55b, rej. 302)" if Array(antt["infPag"]).empty?
      end

      def check_ciot
        issued = time(@ide["dhEmi"])
        since = CIOT_SINCE[@ide["tpAmb"].to_s]
        return unless issued && since && issued >= since && Array(antt["infCIOT"]).empty?

        add "infModal/rodo/infANTT/infCIOT: the CIOT is required for transport for hire (NT 2026.001, rej. 684)"
      end

      def check_payment(payment, path)
        check_tax_id(path, payment, "F56, rej. 727")
        institution = payment.dig("infBanc", "CNPJIPEF")
        add "#{path}/infBanc/CNPJIPEF: #{institution} is not a valid CNPJ (F57, rej. 728)" if institution && !TaxId.valid_cnpj?(institution.to_s)

        total = number(payment["vContrato"])
        components = Array(payment["Comp"]).sum(BigDecimal(0)) { |component| number(component["vComp"]) }
        if (components - total).abs > TOLERANCE
          add "#{path}: the components add up to #{components.to_s("F")}, not the contract's #{total.to_s("F")} (F58, rej. 746)"
        end

        installments = Array(payment["infPrazo"])
        if payment["indPag"].to_s == "1"
          check_installments(payment, installments, total, path)
        else
          add "#{path}/infPrazo: installments are for payment in installments, indPag 1 (F53, rej. 729)" unless installments.empty?
          add "#{path}/vAdiant: an advance is for payment in installments, indPag 1 (F63, rej. 739)" if payment["vAdiant"]
        end
      end

      def check_installments(payment, installments, total, path)
        return add "#{path}/infPrazo: payment in installments lists them (F52, rej. 724)" if installments.empty?

        issued = time(@ide["dhEmi"])&.to_date
        previous = nil
        installments.each_with_index do |installment, index|
          number = installment["nParcela"].to_s
          add "#{path}/infPrazo/nParcela: #{number} should be #{format("%03d", index + 1)} (F59, rej. 735)" unless number == format("%03d", index + 1)
          due = date(installment["dVenc"]) or next

          add "#{path}/infPrazo/dVenc: installment #{number} is due before the manifest's emission (F60, rej. 736)" if issued && due < issued
          add "#{path}/infPrazo/dVenc: installment #{number} is not due after the one before it (F61, rej. 737)" if previous && due <= previous
          previous = due
        end

        sum = installments.sum(BigDecimal(0)) { |installment| number(installment["vParcela"]) } + number(payment["vAdiant"])
        return unless (sum - total).abs > TOLERANCE

        add "#{path}: installments plus advance add up to #{sum.to_s("F")}, not the contract's #{total.to_s("F")} (F62, rej. 738)"
      end

      def check_authorized
        entries = Array(@inf["autXML"])
        entries.each do |entry|
          cnpj, cpf = entry["CNPJ"], entry["CPF"]
          add "autXML/CNPJ: #{cnpj} is not a valid CNPJ (F105, rej. 660)" if cnpj && !TaxId.valid_cnpj?(cnpj.to_s)
          add "autXML/CPF: #{cpf} is not a valid CPF (F106, rej. 661)" if cpf && !TaxId.valid_cpf?(cpf.to_s)
        end
        entries.map { |entry| entry["CNPJ"] || entry["CPF"] }.tally.each do |id, count|
          add "autXML: #{id} is listed #{count} times (F107, rej. 459)" if count > 1
        end
      end

      def check_qr_code
        return add("infMDFeSupl/qrCodMDFe: the QR code's URL is required (F114, rej. 480)") if @qr_code.to_s.empty?

        parts = QrCode.parse(@qr_code)
        return add("infMDFeSupl/qrCodMDFe: #{@qr_code} has no chMDFe and tpAmb (F116, rej. 481)") unless parts

        unless parts[:address].casecmp?(QrCode::URL) || parts[:address].casecmp?(QrCode::URL.sub("https:", "http:"))
          add "infMDFeSupl/qrCodMDFe: the address must be #{QrCode::URL} (F115, rej. 479)"
        end
        key = @inf["@Id"].to_s.delete_prefix("MDFe")
        add "infMDFeSupl/qrCodMDFe: chMDFe differs from the manifest's key, #{key} (F116, rej. 481)" unless parts[:key] == key

        case @ide["tpEmis"].to_s
        when CONTINGENCY
          if parts[:sign].nil?
            add "infMDFeSupl/qrCodMDFe: a manifest in contingency signs its key in `sign` (F117, rej. 482)"
          elsif @signer && !QrCode.signed_by?(key, parts[:sign], @signer)
            add "infMDFeSupl/qrCodMDFe: `sign` is not the key signed with the manifest's certificate (F119, rej. 496)"
          end
        when NORMAL then add "infMDFeSupl/qrCodMDFe: `sign` is for a manifest in contingency only (F118, rej. 488)" if parts[:sign]
        end
      end

      def check_technical_contact
        contact = @inf["infRespTec"] or return

        cnpj = contact["CNPJ"].to_s
        add "infRespTec/CNPJ: #{cnpj} is not a valid CNPJ (F121, rej. 713)" unless TaxId.valid_cnpj?(cnpj)
        add "infRespTec/idCSRT: required with a CSRT" if @csrt && contact["idCSRT"].nil?
      end

      def check_tax_id(path, party, rule, cnpj: "CNPJ", cpf: "CPF")
        return unless party

        value = party[cnpj].to_s
        add "#{path}/#{cnpj}: #{value} is not a valid CNPJ (#{rule})" unless value.empty? || TaxId.valid_cnpj?(value)
        value = party[cpf].to_s
        add "#{path}/#{cpf}: #{value} is not a valid CPF (#{rule})" unless value.empty? || TaxId.valid_cpf?(value)
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

      def date(value)
        return value.to_date if value.respond_to?(:to_date)

        Date.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end
    end
  end
end
