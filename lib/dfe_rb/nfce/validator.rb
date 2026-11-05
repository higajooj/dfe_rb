require "bigdecimal"
require "time"

module DfeRb
  module Nfce
    # The rules of Anexo I that hold only for modelo 65, with the NTs that amend them, checked
    # on top of the NF-e's (Nfe::Validator). Those left to each state (the total it caps, the
    # CSOSNs it bars, home delivery, the cutoff of an NCM...) stay with SEFAZ, and so does a
    # rule another NT words differently; where they disagree on a list, the gem takes the
    # widest one, so it never flags what SEFAZ may accept.
    class Validator
      HOMOLOGACAO = "2"
      OFFLINE = QrCode::OFFLINE
      # tpEmis an NFC-e may take: normal, EPEC (at the state's discretion, NT 2014.003) and
      # off-line contingency (RV B22-34, B22-70).
      EMISSION_TYPES = %w[1 4 9].freeze
      SVC_EMISSION_TYPES = %w[6 7].freeze
      # indPres: in person, home delivery, in person outside the establishment (RV B25b-20, NT 2025.002).
      PRESENCE = %w[1 4 5].freeze
      HOME_DELIVERY = "4"
      OFF_PREMISES = "5"
      # The only CFOPs an NFC-e takes (RV I08-150, with 5.910 from NT 2024.001).
      CFOPS = %w[5101 5102 5103 5104 5115 5405 5656 5667 5910 5933].freeze
      SERVICE_CFOP = "5933"
      # CFOPs of each ICMS treatment (RV N12-40, N12-44, N12a-40, N12a-44; 5.910 from NT 2024.001).
      SALE_CFOPS = %w[5101 5102 5103 5104 5115 5910].freeze
      ST_CFOPS = %w[5405 5656 5667 5910].freeze
      SALE_CODES = %w[00 20 40 41 90 102 103 300 400 900].freeze
      ST_CODES = %w[60 500].freeze
      # The CST and CSOSN an NFC-e takes (RV N12-30 with CST 61 from NT 2023.001, N12a-20);
      # 90 and 900 at the state's discretion, so they aren't flagged.
      CSTS = %w[00 20 40 41 60 61 90].freeze
      CSOSNS = %w[102 103 300 400 500 900].freeze
      # What a state may allow beyond those lists (NT 2023.003 v1.40): CFOP => the CST or
      # CSOSN it goes with.
      STATE_CFOPS = {
        "RS" => {"5949" => %w[90 900]}, "ES" => {"5949" => %w[90 900]},
        "SP" => {"5949" => %w[40 900]}, "AM" => {"5949" => %w[40 900]},
        "CE" => {"5403" => %w[90 900], "5405" => %w[90 900]}
      }.freeze
      # A MEI's NFC-e (RV N12a-81, N12a-91, NT 2024.001).
      MEI = "4"
      MEI_CSOSNS = %w[102 300].freeze
      MEI_CFOP = "5102"
      # tPag an NFC-e can't take: duplicata mercantil, no payment, others (RV YA02-10, -40, -50).
      BARRED_PAYMENTS = {"14" => 857, "90" => 899, "99" => 436}.freeze
      # tPag that carry the card group: credit card, debit card and PIX (RV YA04-10).
      CARD_PAYMENTS = %w[03 04 17].freeze
      # Above this total the consumer must be identified (RV W16-40).
      IDENTIFIED_ABOVE = BigDecimal(10_000)

      # Groups an NFC-e can't carry: [path from infNFe, rejection, what it is].
      BARRED = [
        [%w[ide dhSaiEnt], 705, "a date of entry or exit"],
        [%w[ide dPrevEntrega], 1153, "a delivery forecast"],
        [%w[ide NFref], 708, "referenced documents"],
        [%w[ide gCompraGov], 1006, "the government purchase group"],
        [%w[ide gPagAntecipado], 1146, "the NF-e of an advance payment"],
        [%w[ide cIndOp], 1099, "the indicator of where the supply takes place"],
        [%w[emit IEST], 718, "the issuer's IE as tax substitute"],
        [%w[dest ISUF], 730, "a SUFRAMA registration"],
        [%w[transp retTransp], 755, "ICMS withheld on transport"],
        [%w[transp veicTransp], 756, "a transport vehicle"],
        [%w[transp reboque], 757, "trailers"],
        [%w[transp vagao], 758, "a wagon"],
        [%w[transp balsa], 759, "a ferry"],
        [%w[cobr], 760, "billing (invoice, installments)"],
        [%w[exporta], 814, "the foreign trade group"],
        [%w[compra], 762, "purchase data"],
        [%w[cana], 763, "sugar cane acquisition"]
      ].freeze

      # The same, per item: [path from det, rejection, what it is].
      BARRED_ITEM = [
        [%w[prod veicProd], 736, "new vehicles"],
        [%w[prod arma], 738, "weapons"],
        [%w[prod nRECOPI], 348, "RECOPI (immune paper)"],
        [%w[prod tpCredPresIBSZFM], 1165, "the ZFM IBS sub-assessment class"],
        [%w[imposto ICMSUFDest], 807, "ICMS for the destination state"],
        [%w[imposto IPI], 742, "IPI"],
        [%w[imposto II], 743, "import tax"],
        [%w[imposto PISST], 746, "PIS-ST"],
        [%w[imposto COFINSST], 749, "COFINS-ST"],
        [%w[imposto IBSCBS gCredPresOper], 1049, "the operation's presumed credit"],
        [%w[imposto IBSCBS gCredPresIBSZFM], 1138, "the ZFM presumed credit"],
        [%w[imposto IBSCBS gIBSCBS gCBS gDevTrib], 1187, "the CBS returned"],
        [%w[impostoDevol], 390, "returned taxes"],
        [%w[DFeReferenciado], 708, "a referenced document"]
      ].freeze

      # infnfe: the resolved infNFe tree. supplement: its infNFeSupl ({"qrCode", "urlChave"}),
      # when there is one to check. signer: the OpenSSL certificate that signs the note, to
      # check an off-line QR code's signature. qr_address: the state's QR code consultation
      # address (Endpoints.qr_code), to check the QR code's against.
      def initialize(infnfe, supplement: nil, signer: nil, qr_address: nil)
        @inf = infnfe
        @ide = infnfe["ide"] || {}
        @supplement = supplement
        @signer = signer
        @qr_address = qr_address
        @issues = []
      end

      def issues
        check_identification
        check_barred
        check_recipient
        Array(@inf["det"]).each_with_index { |item, index| check_item(item, index + 1) }
        check_total
        check_transport
        check_payments
        check_qr_code if @supplement
        @issues
      end

      private

      def check_identification
        add "ide/mod: an NFC-e is modelo 65 (DfeRb::Nfe issues modelo 55)" unless @ide["mod"].to_s == "65"
        add "ide/tpNF: an NFC-e is an exit, tpNF 1 (rej. 706)" if @ide["tpNF"].to_s == "0"
        add "ide/idDest: an NFC-e is an internal operation, idDest 1 (rej. 707)" unless @ide["idDest"].to_s == "1"
        add "ide/tpImp: an NFC-e prints the DANFE NFC-e, tpImp 4 or 5 (rej. 709)" unless %w[4 5].include?(@ide["tpImp"].to_s)
        add "ide/finNFe: an NFC-e is a normal note, finNFe 1 (rej. 715)" unless @ide["finNFe"].to_s == "1"
        add "ide/indFinal: an NFC-e is a sale to a final consumer, indFinal 1 (rej. 716)" unless @ide["indFinal"].to_s == "1"

        emission = @ide["tpEmis"].to_s
        if SVC_EMISSION_TYPES.include?(emission)
          add "ide/tpEmis: the SVC doesn't authorize NFC-e; issue it off-line, contingency :offline (rej. 783)"
        elsif !emission.empty? && !EMISSION_TYPES.include?(emission)
          add "ide/tpEmis: #{emission} isn't an NFC-e emission type; use 1 (normal) or 9 (off-line) (rej. 714)"
        end

        presence = @ide["indPres"].to_s
        unless PRESENCE.include?(presence)
          add "ide/indPres: an NFC-e is an in-person sale (1), a home delivery (4) or in person outside the establishment (5) (rej. 717)"
        end
        if @ide["cMunFGIBS"] && presence != OFF_PREMISES
          add "ide/cMunFGIBS: only for a sale in person outside the establishment, indPres 5 (rej. 1000)"
        elsif @ide["cMunFGIBS"].nil? && presence == OFF_PREMISES
          add "ide/cMunFGIBS: required for a sale in person outside the establishment, indPres 5 (rej. 1005)"
        end
      end

      def check_barred
        BARRED.each do |path, rejection, what|
          add "#{path.join("/")}: an NFC-e can't carry #{what} (rej. #{rejection})" if present?(@inf.dig(*path))
        end
      end

      def check_recipient
        dest = @inf["dest"]
        home_delivery = @ide["indPres"].to_s == HOME_DELIVERY
        if dest.nil?
          add "dest: a home delivery (indPres 4) identifies the consumer (rej. 787)" if home_delivery
          return
        end

        add "dest/enderDest: a home delivery (indPres 4) gives the consumer's address (rej. 788)" if home_delivery && dest["enderDest"].nil?
        if dest["indIEDest"] && dest["indIEDest"].to_s != "9"
          add "dest/indIEDest: an NFC-e's consumer is not an ICMS taxpayer, indIEDest 9 (rej. 789)"
        end
        issuer = @inf.dig("emit", "CNPJ")
        add "dest/CNPJ: the consumer can't be the issuer itself (rej. 220)" if issuer && dest["CNPJ"] == issuer
      end

      def check_item(item, number)
        where = "det[#{number}]"
        prod = item["prod"] || {}
        BARRED_ITEM.each do |path, rejection, what|
          add "#{where}/#{path.join("/")}: an NFC-e can't carry #{what} (rej. #{rejection})" if present?(item.dig(*path))
        end
        add "#{where}/prod/indTot: every item of an NFC-e counts in its total, indTot 1 (rej. 774)" if prod["indTot"].to_s == "0"
        if number == 1 && @ide["tpAmb"].to_s == HOMOLOGACAO && prod["xProd"] != Nfe::Resolver::HOMOLOGACAO_ITEM_DESCRIPTION
          add "#{where}/prod/xProd: in homologação the first item is described as " \
            "\"#{Nfe::Resolver::HOMOLOGACAO_ITEM_DESCRIPTION}\" (rej. 373)"
        end
        check_cfop(where, item, prod["CFOP"].to_s)
        check_icms(where, item)
      end

      def check_cfop(where, item, cfop)
        return if cfop.empty?

        code = icms_code(item)
        return if state_cfop?(cfop, code)

        unless CFOPS.include?(cfop)
          return add "#{where}/prod/CFOP: #{cfop} can't be used in an NFC-e, which takes #{CFOPS.join(", ")} (rej. 725)"
        end

        service = !item.dig("imposto", "ISSQN").nil?
        if cfop == SERVICE_CFOP && !service
          add "#{where}/imposto/ISSQN: CFOP 5933 is a service taxed by ISSQN, which the item must carry (rej. 374)"
        elsif cfop != SERVICE_CFOP && service
          add "#{where}/prod/CFOP: an item taxed by ISSQN takes CFOP 5933 (rej. 374)"
        end

        if @inf.dig("emit", "CRT").to_s == MEI && cfop != MEI_CFOP
          add "#{where}/prod/CFOP: a MEI's NFC-e takes CFOP #{MEI_CFOP} only (rej. 337)"
        end
        return unless code

        expected = if SALE_CODES.include?(code)
          SALE_CFOPS
        elsif ST_CODES.include?(code)
          ST_CFOPS
        end
        return if expected.nil? || expected.include?(cfop)

        add "#{where}/prod/CFOP: #{cfop} doesn't go with #{(code.length == 3) ? "CSOSN" : "CST"} #{code}, " \
          "which takes #{expected.join(", ")} (rej. #{(code.length == 3) ? 386 : 382})"
      end

      def check_icms(where, item)
        name, values = Nfe::Totals.icms_variant(item)
        return unless name

        path = "#{where}/imposto/ICMS/#{name}"
        case name
        when "ICMSPart" then return add "#{path}: an NFC-e can't share ICMS between states (rej. 741)"
        when "ICMSST" then return add "#{path}: an NFC-e can't pass on ICMS-ST withheld before (rej. 740)"
        end

        if (cst = values["CST"])
          add "#{path}/CST: an NFC-e takes CST #{CSTS.join(", ")} (rej. 766)" unless CSTS.include?(cst.to_s)
          add "#{path}/modBCST: CST 90 in an NFC-e carries no ICMS-ST (rej. 381)" if name == "ICMS90" && values["modBCST"]
        elsif (csosn = values["CSOSN"])
          add "#{path}/CSOSN: an NFC-e takes CSOSN #{CSOSNS.join(", ")} (rej. 383)" unless CSOSNS.include?(csosn.to_s)
          add "#{path}/modBCST: CSOSN 900 in an NFC-e carries no ICMS-ST (rej. 385)" if name == "ICMSSN900" && values["modBCST"]
          if @inf.dig("emit", "CRT").to_s == MEI && !MEI_CSOSNS.include?(csosn.to_s)
            add "#{path}/CSOSN: a MEI's NFC-e takes CSOSN #{MEI_CSOSNS.join(" or ")} (rej. 782)"
          end
        end
      end

      # Above R$ 10.000,00 the consumer is identified (RV W16-40). Its address (W16-60) and name
      # (W16-50) are each state's call, so SEFAZ checks them.
      def check_total
        total = Nfe::Totals.number(@inf.dig("total", "ICMSTot", "vNF"))
        return unless total > IDENTIFIED_ABOVE

        dest = @inf["dest"] || {}
        if %w[CNPJ CPF idEstrangeiro].none? { |tag| present?(dest[tag]) }
          add "dest: an NFC-e above R$ 10.000,00 identifies the consumer by CNPJ, CPF or foreign id (rej. 750)"
        end
      end

      # Only a home delivery has freight and a carrier, and it must have the carrier (RV X02-10, X03-10, X03-20).
      def check_transport
        transp = @inf["transp"] || {}
        if @ide["indPres"].to_s == HOME_DELIVERY
          add "transp/transporta: a home delivery (indPres 4) names who carries it (rej. 786)" if transp["transporta"].nil?
        else
          add "transp/modFrete: an NFC-e has freight only on a home delivery, indPres 4; use modFrete 9 (rej. 753)" unless transp["modFrete"].to_s == "9"
          add "transp/transporta: an NFC-e names a carrier only on a home delivery, indPres 4 (rej. 754)" if transp["transporta"]
        end
      end

      def check_payments
        Array(@inf.dig("pag", "detPag")).each_with_index do |detail, index|
          path = "pag/detPag[#{index + 1}]"
          kind = detail["tPag"].to_s
          if (rejection = BARRED_PAYMENTS[kind])
            add "#{path}/tPag: an NFC-e can't be paid with tPag #{kind} (#{Nfe::Tables.payment_method(kind)&.title}) (rej. #{rejection})"
          end
          if CARD_PAYMENTS.include?(kind) && detail["card"].nil?
            add "#{path}/card: a card or PIX payment (tPag #{kind}) carries the card group; " \
              "card: {integration: :not_integrated} when the payment isn't integrated with your system (rej. 391)"
          end
        end
      end

      # The QR code's parameters against the note (RV ZX02-2xx and -3xx, NT 2025.001).
      def check_qr_code
        url = @supplement["qrCode"].to_s
        parsed = QrCode.parse(url) or return add "infNFeSupl/qrCode: #{url.inspect} is not a QR code URL (<address>?p=<parameters>)"

        if @qr_address && comparable(parsed[:address]) != comparable(@qr_address)
          add "infNFeSupl/qrCode: #{parsed[:address]} is not the state's QR code consultation, #{@qr_address} (rej. 395)"
        end
        key = @inf["@Id"].to_s.delete_prefix("NFe")
        add "infNFeSupl/qrCode: its key #{parsed[:key]} differs from the note's #{key} (rej. 397)" unless parsed[:key] == key
        version = parsed[:version]
        return add "infNFeSupl/qrCode: version #{version} is not 2 or 3 (rej. 398)" unless %w[2 3].include?(version)
        add "infNFeSupl/qrCode: its tpAmb #{parsed[:environment]} differs from the note's (rej. 397)" unless parsed[:environment] == @ide["tpAmb"].to_s
        offline = @ide["tpEmis"].to_s == OFFLINE
        if version == "2"
          add "infNFeSupl/qrCode: an issuer identified by CPF uses QR code version 3 (rej. 444)" if @inf.dig("emit", "CPF")
          # Its hash needs the CSC, which the gem doesn't hold; the day and total don't.
          check_day_and_total(parsed[:parameters][3], parsed[:parameters][4]) if offline
          return
        end

        if !offline && parsed[:parameters].size > 3
          add "infNFeSupl/qrCode: a note issued on-line carries only key, version and tpAmb, no signature (rej. 445)"
        elsif offline && parsed[:signature].to_s.empty?
          add "infNFeSupl/qrCode: a note issued off-line (tpEmis 9) carries the day, vNF, recipient and signature (rej. 474)"
        elsif offline
          check_offline_qr_code(parsed)
        end
      end

      def check_offline_qr_code(parsed)
        check_day_and_total(parsed[:day], parsed[:total])
        kind, id = QrCode.identification(@inf["dest"])
        unless parsed[:recipient_kind] == kind && parsed[:recipient_id] == id
          add "infNFeSupl/qrCode: its recipient (#{parsed[:recipient_kind]}|#{parsed[:recipient_id]}) differs from dest's (#{kind}|#{id}) (rej. 397)"
        end
        if @signer && !QrCode.signed_by?(parsed[:signed_content], parsed[:signature], @signer)
          add "infNFeSupl/qrCode: its signature doesn't match its parameters and the certificate (rej. 583)"
        end
      end

      # RV ZX02-268 and ZX02-276, of versions 2 and 3.
      def check_day_and_total(day, total)
        issued = time_of(@ide["dhEmi"])
        add "infNFeSupl/qrCode: its day #{day} differs from dhEmi's (rej. 397)" if issued && day != format("%02d", issued.day)
        expected = @inf.dig("total", "ICMSTot", "vNF")
        if expected && total != QrCode.amount(expected)
          add "infNFeSupl/qrCode: its total #{total} differs from vNF #{QrCode.amount(expected)} (rej. 397)"
        end
      end

      # An address as RV ZX02-20 compares it: whatever the case, and the scheme, which the
      # Portal Nacional's list gives either way.
      def comparable(address) = address.to_s.downcase.sub(%r{\Ahttps?://}, "").delete_suffix("/")

      def state_cfop?(cfop, code)
        state = @inf.dig("emit", "enderEmit", "UF")
        allowed = STATE_CFOPS.dig(state, cfop)
        allowed && code && allowed.include?(code)
      end

      def icms_code(item)
        _, values = Nfe::Totals.icms_variant(item)
        (values["CST"] || values["CSOSN"])&.to_s if values
      end

      def present?(value) = !(value.nil? || value == [] || value == {} || value.to_s.empty?)

      def time_of(value)
        return value.to_time if value.is_a?(DateTime)
        return value if value.respond_to?(:day)

        Time.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end

      def add(message)
        @issues << message unless @issues.include?(message)
      end
    end
  end
end
