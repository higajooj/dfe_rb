require "base64"
require "bigdecimal"
require "digest"
require "time"

module DfeRb
  module Nfe
    # Checks locally the business rules SEFAZ enforces and the schema can't express, so a
    # mistake shows up before SEFAZ rejects the note. Only unambiguous rules are here (Anexo I
    # RVs and the NTs that amend them). Rules that depend on state tables stay with SEFAZ.
    class Validator
      TOLERANCE = BigDecimal("0.01")
      # When IBSCBS becomes mandatory for regime normal (RV UB12-10, NT 2025.002 v1.53), by
      # tpAmb. Homologação has rejected a note without it (1115) since 01/07/2026. In
      # production the rule has no date yet ("implementação futura"; v1.51 struck out
      # 03/08/2026), but the group has been mandatory by law since 01/01/2026 (the NT's
      # schedule, LC 214/2025), so a note without it is flagged all the same. The Simples
      # Nacional and the MEI fill it from 2027 (LC 214/2025, art. 348), and NT 2026.005 says
      # how (check_simples_ibs_cbs) but gives no rule for its absence, so nothing is asked of them. Returns and complements are left out:
      # v1.53 exempts only those referencing a note issued before 2027, which until then is
      # every one, so the exception needs the referenced key's date from 2027 on.
      IBS_CBS_SINCE = {"2" => Time.new(2026, 7, 1, 0, 0, 0, "-03:00"), "1" => Time.new(2026, 1, 1, 0, 0, 0, "-03:00")}.freeze
      PRODUCTION = "1"
      NORMAL_REGIME = "3"
      # RV NA01-20 exception 2: in production, the DIFAL group isn't required before this.
      DIFAL_REQUIRED_SINCE = Time.new(2016, 7, 1, 0, 0, 0, "-03:00")
      DEFERRED_PAYMENT_KINDS = Resolver::DEFERRED_PAYMENT_KINDS
      MAX_STANDARD_SERIES = 889
      # The series of an issuer identified by CPF using its own software (RV C02a-10).
      CPF_SERIES = (920..969)
      # procEmi of a note issued with the issuer's own software (RV B26-10, NT 2026.001).
      OWN_SOFTWARE = %w[0 3].freeze
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
      # RV N23-10: the ICMS CSTs/CSOSNs of an operation with ST, whose item carries the CEST,
      # and those (90, 900) that count only with an ST amount withheld (vICMSST).
      CEST_ST_CODES = %w[10 30 60 70 201 202 203 500].freeze
      CEST_ST_AMOUNT_CODES = %w[90 900].freeze
      CFOP_TITLE_LENGTH = 60
      # The notes the IBS/CBS standard rate rules leave alone (UB18-10, UB37-10, UB56-20,
      # exception 2): a return, and the credit notes of a refusal or a reduction in value.
      STANDARD_RATE_EXEMPT_CREDIT_NOTES = %w[03 04 06].freeze
      STANDARD_RATE_KEYS = {"pIBSUF" => :uf, "pIBSMun" => :municipal, "pCBS" => :cbs}.freeze
      CONTRIBUTION_GROUPS = %w[PIS PISST COFINS COFINSST].freeze
      # Length of the xJust of a note in contingency (B29).
      CONTINGENCY_REASON_LENGTH = (15..256)
      # The rules on what a note references (NT 2026.002), by tpAmb: when BA03-10, BA10-10 and
      # BA20-30 bar a paper note, a rural producer's note and a cupom fiscal (v1.10), and when
      # BA02-35, VC02-40 and I08-180 bar a consumer's note (v1.11 moved them to 14/12/2026 in
      # production).
      PAPER_REFERENCES_BARRED_SINCE = {"2" => Time.new(2026, 9, 1, 0, 0, 0, "-03:00"), "1" => Time.new(2026, 10, 5, 0, 0, 0, "-03:00")}.freeze
      CONSUMER_REFERENCES_BARRED_SINCE = {"2" => Time.new(2026, 9, 1, 0, 0, 0, "-03:00"), "1" => Time.new(2026, 12, 14, 0, 0, 0, "-03:00")}.freeze
      # The models an exit note may not reference (BA02-35, VC02-40): the NFC-e and the CF-e SAT.
      CONSUMER_MODELS = {"65" => "an NFC-e (modelo 65)", "59" => "a CF-e SAT (modelo 59)"}.freeze
      # A complement and a return may still reference them, and so may a debit note of
      # unprocessed notes (03) or of fines and interest (04), on an item (VC02-40).
      CONSUMER_REFERENCE_PURPOSES = %w[2 4].freeze
      CONSUMER_REFERENCE_DEBIT_NOTES = %w[03 04].freeze
      # The CFOPs of a note issued for a sale a cupom fiscal covered (I08-180).
      RETAIL_DOCUMENT_CFOPS = %w[5929 6929].freeze

      # NT 2026.008 (v1.01): when the rules on the net value (I11c-20, W01a-10, W01a-20) and on the
      # ICMS of an advance payment (NB01-10, NB01-20) apply, by tpAmb. Homologação by 26/10/2026;
      # production moved from 16/11 to 14/12/2026 by the Portal's aviso of 13/11/2026. NB01-30 has
      # its own, later dates (01/02/2027 in homologação, 01/03/2027 in production). I11c-10
      # (vProdLiq required) is "implementação futura" and not checked.
      NET_VALUE_RULES_SINCE = {"2" => Time.new(2026, 10, 26, 0, 0, 0, "-03:00"), "1" => Time.new(2026, 12, 14, 0, 0, 0, "-03:00")}.freeze
      PREPAID_ICMS_REQUIRED_SINCE = {"2" => Time.new(2027, 2, 1, 0, 0, 0, "-03:00"), "1" => Time.new(2027, 3, 1, 0, 0, 0, "-03:00")}.freeze
      # tpOperGov 4: receipt of a payment with a later supply (NB01-20, NB01-30).
      ADVANCE_PAYMENT_OPERATION = "4"
      # tpNFDebito 06, the debit note of an advance payment (B25-80, NB01), and 07, of a loss in stock.
      ADVANCE_PAYMENT_DEBIT_NOTE = "06"
      STOCK_LOSS_DEBIT_NOTE = "07"
      # The groups a debit or credit note may not carry (RV B25-80); it is IBS/CBS only.
      IBS_CBS_ONLY_BARRED_GROUPS = %w[ICMS ISSQN IPI II PIS PISST COFINS COFINSST ICMSUFDest].freeze
      CONTRIBUTION_GROUPS_OF_2026 = %w[PIS PISST COFINS COFINSST].freeze

      # NT 2026.005 v1.00 (the Simples Nacional's IBS and CBS): when its rules apply, by tpAmb.
      # Homologação by 26/10/2026; production moved from 16/11 to 14/12/2026 by the Portal's aviso
      # of 13/11/2026.
      SIMPLES_IBS_CBS_RULES_SINCE = {"2" => Time.new(2026, 10, 26, 0, 0, 0, "-03:00"), "1" => Time.new(2026, 12, 14, 0, 0, 0, "-03:00")}.freeze
      # The notes whose IBSCBS mirrors the supply note they refer to (NT 2026.005 §2.4), issued
      # perhaps under another regime than the issuer's today: a return, the credit notes 03 and 06
      # and the debit note 09.
      MIRROR_CREDIT_NOTES = %w[03 06].freeze
      MIRROR_DEBIT_NOTE = "09"

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

        # An NFC-e may leave its consumer unnamed, without address, or out (Nfce::Validator).
        check_recipient(@inf["dest"]) unless nfce?

        state = emit&.dig("enderEmit", "UF")
        return unless state && States::CODES.key?(state)

        city = emit.dig("enderEmit", "cMun").to_s
        add "emit/enderEmit/cMun: city #{city} does not belong to #{state} (rej. 273)" unless city.start_with?(States.code(state))
        fg = @ide["cMunFG"].to_s
        add "ide/cMunFG: city #{fg} does not belong to #{state} (rej. 271)" unless fg.empty? || fg.start_with?(States.code(state))
      end

      def check_recipient(dest)
        return add "dest: the recipient is mandatory in NF-e modelo 55 (rej. 719)" if dest.nil?

        add "dest/xNome: the recipient name is mandatory (rej. 724)" if dest["xNome"].to_s.empty?
        add "dest/enderDest: the recipient address is mandatory (rej. 726)" if dest["enderDest"].nil?
        add "dest: give the recipient's CNPJ, CPF or foreign id" if dest["idEstrangeiro"].nil? && dest["CNPJ"].nil? && dest["CPF"].nil?
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
        check_series
        add "ide/nNF: the invoice number is required" if @ide["nNF"].nil?
        add "ide/natOp: the nature of the operation is required" if @ide["natOp"].to_s.empty?

        dest = @inf["dest"] || {}
        if dest["indIEDest"].to_s == "9" && @ide["tpNF"].to_s == "1" && @ide["idDest"].to_s != "3" && @ide["indFinal"].to_s != "1"
          add "ide/indFinal: must be 1 (final consumer) when the recipient is not an ICMS taxpayer (rej. 696)"
        end

        check_purpose_direction
        check_contingency
        check_references

        presence = [2, 3, 4, 9].include?(@ide["indPres"].to_i)
        if presence && @ide["indIntermed"].nil?
          add "ide/indIntermed: required when indPres is 2, 3, 4 or 9 (rej. 434)"
        elsif !presence && !@ide["indIntermed"].nil?
          add "ide/indIntermed: only allowed when indPres is 2, 3, 4 or 9 (rej. 435)"
        end
      end

      # The series of a note issued with the issuer's own software (procEmi 0 or 3): 0 to 889
      # for a CNPJ (RV B26-10 and C02-30), 920 to 969 for a CPF (B26-10 and C02a-10).
      def check_series
        return unless OWN_SOFTWARE.include?(@ide["procEmi"].to_s)

        series = @ide["serie"].to_i
        if !@inf.dig("emit", "CPF").to_s.empty?
          unless CPF_SERIES.cover?(series)
            add "ide/serie: #{series} doesn't fit an issuer identified by CPF, whose own software uses series " \
              "#{CPF_SERIES.min} to #{CPF_SERIES.max} (rej. 244, 495)"
          end
        elsif series > MAX_STANDARD_SERIES
          add "ide/serie: #{series} is reserved (own software uses series 0 to #{MAX_STANDARD_SERIES}, rej. 244)"
        end
      end

      # Checks tpEmis and what a note in contingency must say (RVs B22 and B28): since when
      # and why, and the SVC of its own state.
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
        if emission == "9" && !nfce? && @ide["tpImp"].to_s != "6"
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

      # What an NF-e may reference (NT 2026.002). An NFC-e references nothing at all
      # (Nfce::Validator), so these hold for modelo 55.
      def check_references
        return if nfce?

        references = Array(@ide["NFref"])
        if in_force?(PAPER_REFERENCES_BARRED_SINCE)
          references.each_with_index do |reference, index|
            path = "ide/NFref[#{index + 1}]"
            add "#{path}/refNF: an NF-e can't reference a paper note, modelo 1 or 2 (RV BA03-10, rej. 681)" if reference["refNF"]
            add "#{path}/refNFP: an NF-e can't reference a rural producer's paper note (RV BA10-10, rej. 682)" if reference["refNFP"]
            add "#{path}/refECF: an NF-e can't reference a cupom fiscal (RV BA20-30, rej. 924)" if reference["refECF"]
          end
        end
        return unless in_force?(CONSUMER_REFERENCES_BARRED_SINCE)

        check_consumer_references(references)
        check_retail_document_references(references)
      end

      # RV BA02-35 and VC02-40: an exit note other than a complement or a return can't
      # reference a consumer's note, by its key (rej. 679); its items may still on a debit
      # note of types 03 and 04 (VC02-40's exception). An NF-e printed as the DANFE
      # Simplificado Tipo 2 is barred too, but its key doesn't tell, so SEFAZ checks that one.
      def check_consumer_references(references)
        return unless @ide["tpNF"].to_s == "1" && !CONSUMER_REFERENCE_PURPOSES.include?(@ide["finNFe"].to_s)

        references.each_with_index do |reference, index|
          model = CONSUMER_MODELS[model_of(reference["refNFe"])] or next

          add "ide/NFref[#{index + 1}]/refNFe: an exit note can't reference #{model}, unless it complements or returns " \
            "it (finNFe 2 or 4) (RV BA02-35, rej. 679)"
        end
        return if CONSUMER_REFERENCE_DEBIT_NOTES.include?(@ide["tpNFDebito"].to_s)

        Array(@inf["det"]).each_with_index do |item, index|
          model = CONSUMER_MODELS[model_of(item.dig("DFeReferenciado", "chaveAcesso"))] or next

          add "det[#{index + 1}]/DFeReferenciado/chaveAcesso: an exit note's item can't reference #{model}, unless the " \
            "note complements or returns it (finNFe 2 or 4) (RV VC02-40, rej. 679)"
        end
      end

      # RV I08-180: a note for a sale a cupom fiscal covered (CFOP 5929 or 6929) can't
      # reference an NFC-e (rej. 375).
      def check_retail_document_references(references)
        return unless references.any? { |reference| model_of(reference["refNFe"]) == Resolver::NFCE }

        Array(@inf["det"]).each_with_index do |item, index|
          cfop = item.dig("prod", "CFOP").to_s
          next unless RETAIL_DOCUMENT_CFOPS.include?(cfop)

          add "det[#{index + 1}]/prod/CFOP: a note for a sale a cupom fiscal covered (#{cfop}) can't reference an NFC-e " \
            "(RV I08-180, rej. 375)"
        end
      end

      # ide/mod of an access key: its 21st and 22nd characters.
      def model_of(key) = key.to_s[20, 2]

      # Whether a rule dated by tpAmb applies to the note's issue date.
      def in_force?(since_by_environment)
        since = since_by_environment[@ide["tpAmb"].to_s]
        since && issued_at && issued_at >= since
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

        check_net_value(where, prod)
        check_simples_ibs_cbs(where, item)
        check_item_cfop(where, item)
        check_ibs_cbs_only_purpose(where, item)
        check_prepaid_icms(where, item)
        check_gtin("#{where}/prod/cEAN", prod["cEAN"])
        check_gtin("#{where}/prod/cEANTrib", prod["cEANTrib"])
        check_manufacturer(where, prod)
        check_cest(where, item, prod)
        check_icms(where, item)
        check_item_taxes(where, item)
      end

      # NT 2026.005 §2.1 to §2.3: what the issuer's regime lets its item carry of the IBS and the
      # CBS (SimplesIbsCbs). The NT gives these as a table, with no rejection code. A MEI (CRT 4)
      # carries no IBSCBS at all; tpRegimeIBSCBS is given only where the table names it; cAtivSN
      # only by an optante or one whose option is pending; and gIBSCBS and the groups of gTribSN
      # are left out where the table says "não informar". What the table says to "informar" is
      # left to SEFAZ, which publishes no rule for it, and so is a note whose IBSCBS mirrors a
      # supply (§2.4: returns and refusals), which may carry the regime the supply had.
      def check_simples_ibs_cbs(where, item)
        return unless in_force?(SIMPLES_IBS_CBS_RULES_SINCE)

        layout = SimplesIbsCbs.layout(@inf["emit"]) or return
        add "emit/tpRegimeIBSCBS: #{layout.problem}" if layout.problem
        ibscbs = item.dig("imposto", "IBSCBS")
        if layout.mei
          add "#{where}/imposto/IBSCBS: a MEI (CRT 4) doesn't inform the IBS/CBS group (NT 2026.005 §2.3)" if ibscbs
          return
        end
        if item.dig("prod", "cAtivSN") && !layout.activity
          add "#{where}/prod/cAtivSN: only a Simples Nacional issuer, or one whose option for it is pending (tpRegimeIBSCBS 2, 3 or 4), informs it (NT 2026.005 §2.2)"
        end
        return if ibscbs.nil? || mirror_note? || layout.problem

        path = "#{where}/imposto/IBSCBS"
        add "#{path}/gIBSCBS: not informed by a Simples Nacional issuer without the regular regime of the IBS and the CBS (NT 2026.005 §2.3)" if layout.main == false && ibscbs["gIBSCBS"]
        simples = ibscbs["gTribSN"] or return
        if layout.ibs_sn == false && layout.cbs_sn == false
          add "#{path}/gTribSN: not informed with this regime (NT 2026.005 §2.3)"
        else
          add "#{path}/gTribSN/gIBSSN: not informed with this regime (NT 2026.005 §2.3)" if layout.ibs_sn == false && simples["gIBSSN"]
          add "#{path}/gTribSN/gCBSSN: not informed with this regime (NT 2026.005 §2.3)" if layout.cbs_sn == false && simples["gCBSSN"]
        end
      end

      def mirror_note?
        @ide["finNFe"].to_s == "4" || MIRROR_CREDIT_NOTES.include?(credit_note_type) || debit_note_type == MIRROR_DEBIT_NOTE
      end

      # RV I11c-20 (NT 2026.008): on a normal note, vProdLiq is the net unit price x the quantity.
      def check_net_value(where, prod)
        return unless in_force?(NET_VALUE_RULES_SINCE) && @ide["finNFe"].to_s == "1"
        return if prod["vProdLiq"].nil? || prod["vUnComLiq"].nil?

        check_amount("#{where}/prod/vProdLiq", prod["vProdLiq"], Totals.net_item_amount(prod), "net unit price x quantity", 1279)
      end

      # RV B25-80 (NT 2025.002 v1.53, exceções 2 to 4 with NT 2026.008): a debit or credit note, or
      # the receipt of a payment (tpOperGov 2), is for the IBS and the CBS only, whatever the item
      # carries of the other taxes. The credit notes of a refusal or a reduction (03, 04, 06) and
      # the debit note of a loss in stock (07) are left out. A debit note of an advance payment (06)
      # may carry the IPI, the ICMS expected at the supply (NB01) and, in 2026, PIS and COFINS.
      def check_ibs_cbs_only_purpose(where, item)
        return if nfce?
        return unless %w[5 6].include?(@ide["finNFe"].to_s) || @ide.dig("gCompraGov", "tpOperGov").to_s == "2"
        return if DEVOLUTION_CREDIT_NOTES.include?(credit_note_type) || debit_note_type == STOCK_LOSS_DEBIT_NOTE

        imposto = item["imposto"] || {}
        prepaid = debit_note_type == ADVANCE_PAYMENT_DEBIT_NOTE
        found = IBS_CBS_ONLY_BARRED_GROUPS.select { |tag| imposto[tag] }
        found << "impostoDevol" if item["impostoDevol"]
        found.each do |tag|
          next if prepaid && tag == "IPI"
          next if prepaid && tag == "ICMS" && imposto["ICMS"].keys == [Sugar::PREPAID_ICMS]
          next if prepaid && CONTRIBUTION_GROUPS_OF_2026.include?(tag) && (issued_at.nil? || issued_at.year <= 2026)

          add "#{where}/#{(tag == "impostoDevol") ? tag : "imposto/#{tag}"}: a debit or credit note carries IBS and CBS only (RV B25-80, rej. 1001)"
        end
      end

      # RV NB01-10, NB01-20 and NB01-30 (NT 2026.008): the ICMS expected at the supply of an advance
      # payment goes on an NF-e of a debit note of type 06 or of tpOperGov 4, on every item, and on
      # no other note, an NFC-e least of all. Its absence is flagged from NB01-30's own date.
      def check_prepaid_icms(where, item)
        group = item.dig("imposto", "ICMS", Sugar::PREPAID_ICMS)
        advance = debit_note_type == ADVANCE_PAYMENT_DEBIT_NOTE || @ide.dig("gCompraGov", "tpOperGov").to_s == ADVANCE_PAYMENT_OPERATION
        path = "#{where}/imposto/ICMS/#{Sugar::PREPAID_ICMS}"
        if group
          return unless in_force?(NET_VALUE_RULES_SINCE)

          if nfce?
            add "#{path}: an NFC-e can't carry the ICMS expected at the supply of an advance payment (RV NB01-10, rej. 1280)"
          elsif !advance
            add "#{path}: only a debit note of type 06 (tpNFDebito) or tpOperGov 4 carries it (RV NB01-20, rej. 1280)"
          end
        elsif advance && !nfce? && in_force?(PREPAID_ICMS_REQUIRED_SINCE)
          add "#{path}: required on an advance payment (tpNFDebito 06 or tpOperGov 4), 0.00 if no ICMS falls at the supply (RV NB01-30, rej. 1281)"
        end
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
      # the DIFAL group, with the rule's exceptions (NT 2025.002 v1.32, unchanged through v1.53).
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

      def debit_note_type = @ide["tpNFDebito"].to_s.rjust(2, "0")

      def nfce? = @ide["mod"].to_s == "65"

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

      # RV I05e-10: goods not produced on a relevant scale name their manufacturer (rej. 879).
      # RV I05e-20: whose CNPJ has valid check digits (rej. 489).
      def check_manufacturer(where, prod)
        cnpj = prod["CNPJFab"].to_s
        if cnpj.empty?
          add "#{where}/prod/CNPJFab: required when indEscala is N, not produced on a relevant scale (rej. 879)" if prod["indEscala"].to_s == "N"
        elsif !TaxId.valid_cnpj?(cnpj)
          add "#{where}/prod/CNPJFab: #{cnpj} is not a valid CNPJ (check digits, rej. 489)"
        end
      end

      # RV N23-10: an NF-e item with ST carries its CEST (rej. 806), except in the ICMSPart group.
      def check_cest(where, item, prod)
        name, values = Totals.icms_variant(item)
        return if values.nil? || name == "ICMSPart" || nfce? || !prod["CEST"].to_s.empty?

        code = (values["CST"] || values["CSOSN"]).to_s
        st = CEST_ST_CODES.include?(code) || CEST_ST_AMOUNT_CODES.include?(code) && Totals.number(values["vICMSST"]).positive?
        add "#{where}/prod/CEST: required for an operation with ICMS-ST, #{values["CST"] ? "CST" : "CSOSN"} #{code} (rej. 806)" if st
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
        check_contributions_ended(where, imposto)
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
        check_ibs_cbs_codes(where, item, imposto["IBSCBS"])
        check_ibs_cbs_item(where, imposto["IBSCBS"])
        return unless item["vItem"] && issued_at
        # VB01-10 and VB01-20, exceção 2 (NT 2026.008 v1.01): not on an import.
        return if item.dig("prod", "CFOP").to_s.start_with?("3")

        check_amount("#{where}/vItem", item["vItem"], Totals.item_amount(item, issued_at.year),
          "the sum of the values that make it up", 1105)
      end

      # One row per sphere: its group, rate and amount tags, and the rejection codes for the
      # amount, the effective rate, the rate under regular taxation, and gDif missing where
      # the CST requires it or given where it doesn't allow it.
      IBS_CBS_SPHERES = [
        ["gIBSUF", "pIBSUF", "vIBSUF", {amount: 1041, effective: 1035, rate: 1026, deferral: 1030, no_deferral: 1029}],
        ["gIBSMun", "pIBSMun", "vIBSMun", {amount: 1052, effective: 1035, rate: 1036, deferral: 1044, no_deferral: 1083}],
        ["gCBS", "pCBS", "vCBS", {amount: 1069, effective: 1064, rate: 1037, deferral: 1061, no_deferral: 1090}]
      ].freeze

      # The rules that consult the IT 2025.002 tables (NT 2025.002): the item's cClassTrib,
      # then the operation's presumed credit (gCredPresOper).
      def check_ibs_cbs_codes(where, item, ibscbs)
        return unless ibscbs

        path = "#{where}/imposto/IBSCBS"
        klass = check_classification(path, ibscbs)
        check_presumed_credit("#{path}/gCredPresOper", item, ibscbs["gCredPresOper"], klass) if ibscbs["gCredPresOper"]
      end

      # RV UB14-10: the cClassTrib is in the table and in force on the issue date (rej. 1023);
      # UB14-20: it opens with the CST (1024); UB14-25: it may go on the note's model (1025).
      # A revoked code is accepted on a note issued before its end, and its model indicators,
      # which the table clears on revoking it, aren't consulted; nor are any code's on a note
      # issued before the tables' version (Tables::IBS_CBS_INDICATORS_SINCE). Returns the
      # Classification the other rules may consult, nil when there's none.
      def check_classification(path, ibscbs)
        code = ibscbs["cClassTrib"] or return
        klass = Tables.classification(code)
        unless klass
          add "#{path}/cClassTrib: #{code} is not in the cClassTrib table (IT 2025.002) (rej. 1023)"
          return
        end
        if issued_at && !klass.valid_on?(issued_at)
          span = klass.valid_until ? "from #{klass.valid_from} until the day before #{klass.valid_until}" : "from #{klass.valid_from}"
          add "#{path}/cClassTrib: #{code} is not in force on #{Tables.day(issued_at)}, only #{span} (IT 2025.002) (rej. 1023)"
          return
        end
        cst = ibscbs["CST"]
        if cst && !code.to_s.start_with?(cst.to_s)
          add "#{path}/cClassTrib: #{code} doesn't belong to CST #{cst}, its first three digits are its CST (rej. 1024)"
        end
        if klass.valid_until.nil? && current_ibs_cbs_indicators? && !klass.model?(@ide["mod"] || "55")
          add "#{path}/cClassTrib: #{code} can't go on a modelo #{@ide["mod"] || "55"} note (#{nfce? ? "indNFCe" : "indNFe"} 0, IT 2025.002) (rej. 1025)"
        end
        klass
      end

      # The operation's presumed credit on an NF-e (NT 2025.002 UB120-20 to UB130-10). An
      # NFC-e can't carry it at all (UB120-10, Nfce::Validator).
      # The indicator rules (UB120-20, UB123, UB127) consult the tables' current indicators, so
      # they hold for notes issued from Tables::IBS_CBS_INDICATORS_SINCE.
      # One row per tax: its group, then the rejections for the group given where the cCredPres
      # bars it, left out where it requires it, a used good's credit above vProd, and an amount
      # in suspensive condition given when it can't be, with the first year it can (the IBS
      # from 2033, UB126-10; the CBS from 2027, UB130-10).
      PRESUMED_CREDIT_TAXES = [
        ["gIBSCredPres", :ibs, {barred: 1053, required: 1054, above_value: 1107, suspended: 1056, suspended_since: 2033}],
        ["gCBSCredPres", :cbs, {barred: 1050, required: 1058, above_value: 1124, suspended: 1060, suspended_since: 2027}]
      ].freeze
      # cCredPres 4: used movable goods bought from a non-taxpayer individual for resale.
      USED_GOODS_CREDIT = "04"

      def check_presumed_credit(path, item, credit, klass)
        return if nfce?

        indicators = current_ibs_cbs_indicators?
        if indicators && klass && !klass.presumed_credit? && item.dig("prod", "indBemMovelUsado").to_s != "1"
          add "#{path}: not allowed for cClassTrib #{klass.code}, whose ind_gCredPresOper is 0 (rej. 1175)"
        end
        code = credit["cCredPres"] or return
        row = Tables.presumed_credit(code)
        unless row
          add "#{path}/cCredPres: #{code} is not in the cCredPres table (IT 2025.002) (rej. 1055)"
          return
        end

        PRESUMED_CREDIT_TAXES.each do |tag, tax, codes|
          group = credit[tag]
          if indicators && group && row.public_send(tax) == false
            add "#{path}/#{tag}: not allowed for cCredPres #{row.code} (rej. #{codes[:barred]})"
          elsif indicators && group.nil? && row.public_send(tax)
            add "#{path}/#{tag}: required for cCredPres #{row.code} (rej. #{codes[:required]})"
          end
          next unless group

          if row.code == USED_GOODS_CREDIT && Totals.number(group["vCredPres"]) > Totals.number(item.dig("prod", "vProd"))
            add "#{path}/#{tag}/vCredPres: a used good's credit can't exceed vProd (rej. #{codes[:above_value]})"
          end
          if group["vCredPresCondSus"] && (row.code != USED_GOODS_CREDIT || (issued_at && issued_at.year < codes[:suspended_since]))
            add "#{path}/#{tag}/vCredPresCondSus: only for cCredPres #{USED_GOODS_CREDIT} from #{codes[:suspended_since]} " \
              "(rej. #{codes[:suspended]})"
          end
        end
      end

      # Whether the note is issued when the tables' indicators hold (an undated one is taken as now).
      def current_ibs_cbs_indicators? = issued_at.nil? || Tables.day(issued_at) >= Tables::IBS_CBS_INDICATORS_SINCE

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
          elsif !klass&.regular_taxation?
            check_standard_rate(path, sphere, rate_tag, codes[:rate])
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

      # The rate of each sphere is the one the law fixes for the issue year (RV UB18-10, UB37-10,
      # UB56-10, UB56-20), when the gem knows it. A return and the credit notes of a refusal or
      # a reduction carry the rates of the operation they refer to. A CBS of zero is the
      # incentive areas' (ZFM and ALC): with gALCZFMCBS from 2027, and under conditions on the
      # NCM and the parties' cities in 2026, which are left to SEFAZ. A government purchase
      # (gCompraGov) is left to SEFAZ too.
      def check_standard_rate(path, sphere, rate_tag, rejection)
        return if sphere[rate_tag].nil? || issued_at.nil? || @ide["gCompraGov"]
        return if @ide["finNFe"].to_s == "4" || (@ide["tpNFCredito"] && STANDARD_RATE_EXEMPT_CREDIT_NOTES.include?(credit_note_type))

        year = issued_at.year
        # As the XML writes it: 4 places at most.
        given = Calculator.percentage(sphere[rate_tag])
        # The CBS of an excess of the sublimit is in gTribSN: gIBSCBS carries it at zero (NT 2026.005 §2.3).
        zero_cbs = rate_tag == "pCBS" && (sphere["gALCZFMCBS"] || SimplesIbsCbs.layout(@inf["emit"])&.zero_cbs)
        expected = zero_cbs ? BigDecimal(0) : Rates.ibs_cbs(year)[STANDARD_RATE_KEYS.fetch(rate_tag)]
        return if expected.nil? || given == expected
        return if rate_tag == "pCBS" && given.zero? && year < Rates::CBS_CHARGED_SINCE

        add "#{path}/#{rate_tag}: #{sphere[rate_tag]} is not the rate the law fixes for #{year} (#{expected.to_s("F")}) (rej. #{rejection})"
      end

      # PIS/Pasep and COFINS end with 2026 (EC 132/2023, ADCT art. 126, II; LC 214/2025, art.
      # 542): a normal note issued later carries no rate or amount of them. Each group is still
      # mandatory (RV Q01-20, S01-20, NT 2025.002 v1.53), with a CST that charges nothing until
      # an NT says otherwise. A return or a complement may carry those of the 2026 operation it
      # refers to.
      def check_contributions_ended(where, imposto)
        return unless @ide["finNFe"].to_s == "1" && issued_at && !Rates.pis_cofins_charged?(issued_at.year)

        CONTRIBUTION_GROUPS.each do |name|
          group = imposto[name] or next
          group = group.values.first unless name.end_with?("ST")
          next unless group.is_a?(Hash)

          tax = name.delete_suffix("ST")
          charged = ["p#{tax}", "v#{tax}", "vAliqProd"].find { |tag| !Totals.number(group[tag]).zero? }
          next unless charged

          add "#{where}/imposto/#{name}/#{charged}: PIS/Pasep and COFINS are not charged on a note issued from 2027 " \
            "(EC 132/2023, ADCT art. 126, II; LC 214/2025, art. 542)"
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
        check_net_total(det, total)
        check_simples_totals(det, total)
        given = total["ICMSTot"] or return
        expected = Totals.icms_total(det)
        expected.each do |tag, value|
          next if given[tag].nil?

          check_amount("total/ICMSTot/#{tag}", given[tag], value, "the sum of the items")
        end
      end

      # RV W01a-10 and W01a-20 (NT 2026.008): vProdLiqTot is there once an item gives vProdLiq, and
      # is the sum of them.
      def check_net_total(det, total)
        return unless in_force?(NET_VALUE_RULES_SINCE)

        net = Totals.net_total(det)
        if net && total["vProdLiqTot"].nil?
          add "total/vProdLiqTot: required when an item gives vProdLiq (RV W01a-10, rej. 1282)"
        elsif total["vProdLiqTot"]
          check_amount("total/vProdLiqTot", total["vProdLiqTot"], net || 0, "the sum of the items' vProdLiq", 1283)
        end
      end

      # RV W59h-10, W59h-20, W59i-10, W59j-10 (NT 2026.005): the Simples Nacional's totals are there
      # when an item carries gTribSN, and only then, and each is the sum of the items' own.
      def check_simples_totals(det, total)
        return unless in_force?(SIMPLES_IBS_CBS_RULES_SINCE)

        carrying = det.filter_map { |item| item.dig("imposto", "IBSCBS", "gTribSN") }
        given = total.dig("IBSCBSTot", "gTribSN")
        path = "total/IBSCBSTot/gTribSN"
        if given.nil?
          add "#{path}: required when an item carries gTribSN (RV W59h-10, rej. 1275)" unless carrying.empty?
          return
        end
        return add "#{path}: no item carries gTribSN (RV W59h-20, rej. 1276)" if carrying.empty?

        check_amount("#{path}/vIBSSN", given["vIBSSN"], Totals.sum(carrying) { |group| group.dig("gIBSSN", "vIBSSN") },
          "the sum of the items' vIBSSN", 1277)
        check_amount("#{path}/vCBSSN", given["vCBSSN"], Totals.sum(carrying) { |group| group.dig("gCBSSN", "vCBSSN") },
          "the sum of the items' vCBSSN", 1284)
      end

      def check_payment
        details = Array(@inf.dig("pag", "detPag"))
        if details.empty?
          return add "pag/detPag: at least one payment is required (use kind: :no_payment for none)"
        end

        details.each_with_index do |detail, index|
          check_payment_kind("pag/detPag[#{index + 1}]/tPag", detail["tPag"].to_s)
          check_card("pag/detPag[#{index + 1}]/card", detail["card"]) if detail["card"]
        end
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

      # A card payment integrated with the issuer's system names its acquirer and authorization
      # code (RV YA05-10), with a valid CNPJ (YA05-20), and its brand is in the table (YA06-10).
      def check_card(path, card)
        if card["tpIntegra"].to_s == "1" && (card["CNPJ"].to_s.empty? || card["cAut"].to_s.empty?)
          add "#{path}: an integrated payment (tpIntegra 1) gives the acquirer's CNPJ and the authorization code, cAut (rej. 392)"
        end
        cnpj = card["CNPJ"].to_s
        add "#{path}/CNPJ: #{cnpj} is not a valid CNPJ (check digits, rej. 437)" unless cnpj.empty? || TaxId.valid_cnpj?(cnpj)
        brand = card["tBand"].to_s
        unless brand.empty? || Tables.card_brands.key?(brand)
          add "#{path}/tBand: #{brand} is not a card brand (see DfeRb::Nfe::Tables.card_brands, rej. 443)"
        end
      end

      # RV YA03-10 is only active for NFC-e ("implementação futura para modelo 55").
      def check_payment_total(details)
        return unless nfce?
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

      # Every item of a regime normal issuer must carry IBS/CBS (RV UB12-10). It is a rejection
      # in homologação and only the law's requirement in production. A devolução (finNFe 4) is
      # exempt, and so is a complementar note that references a note issued before 2027. The
      # gem can't tell that case apart, so it skips finNFe 2 and leaves it to SEFAZ.
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

      # Compares a given amount with the expected one, rounded as the XML would show it.
      # Skips the check when there is no expected value (one the gem can't compute).
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
