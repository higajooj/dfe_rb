module DfeRb
  module Nfe
    # What NT 2026.007 v1.11 asks of an issuer without IE, the contribuinte exclusivo do
    # IBS/CBS: one that leaves emit/IE out, which the NT lets an NF-e do (C17 occurs 0-1) and
    # which SEFAZ confirms against the CCC. The rules that read only the note are here; the
    # ones that consult SEFAZ's registries (LCC-RFB and CCC: 12C02-10, 12C02-20, 12C21-20,
    # 1P10-30, 1P10-32, 1C17-02, 1C17-04, 5AF15 to 5BG17, 12E02 to 12G02) stay with SEFAZ.
    # C17-11 (the SVRS authorizes the note, rej. 166) is the client's routing
    # (Client#authorize), and I08-191 (the CFOPs, rej. 159) is in Validator with the CFOP
    # rules. Mixed into Validator, whose `add`, `in_force?` and `issued_at` it uses.
    module NoIeRules
      # The days v1.11 gives the rules, by tpAmb: "Até 26/10/2026" in homologação and
      # 16/11/2026 in production (v1.00 had them on 01/09 and 03/11/2026).
      NO_IE_RULES_SINCE = {"2" => Time.new(2026, 10, 26, 0, 0, 0, "-03:00"), "1" => Time.new(2026, 11, 16, 0, 0, 0, "-03:00")}.freeze
      # RV C17-42 (rej. 156) holds until this year, when "a regra NÃO se aplica a partir de 2033".
      NFCE_ALLOWED_FROM_YEAR = 2033

      private

      # The checks of an issuer without IE, from the day the NT starts.
      def check_issuer_without_ie
        return unless without_ie? && in_force?(NO_IE_RULES_SINCE)

        check_no_ie_nfce
        return if nfce?

        check_no_ie_tax_id
        check_no_ie_substitute
        Array(@inf["det"]).each_with_index do |item, index|
          check_no_ie_icms(item, index + 1)
          check_no_ie_ibs_cbs(item, index + 1)
        end
      end

      # Whether the issuer is named without an IE (an "ISENTO" is an IE, and is the CCC's to
      # judge, 1C17-02 and 1C17-04).
      def without_ie?
        emit = @inf["emit"]
        !emit.nil? && emit["IE"].to_s.strip.empty?
      end

      # RV C17-42 (rej. 156): an NFC-e needs the IE, until 2033.
      def check_no_ie_nfce
        return unless nfce? && issued_at && issued_at.year < NFCE_ALLOWED_FROM_YEAR

        add "emit/IE: an NFC-e (modelo 65) can't be issued without the issuer's state registration until #{NFCE_ALLOWED_FROM_YEAR} " \
          "(RV C17-42, NT 2026.007, rej. 156)"
      end

      # RV C17-43 (rej. 157, SVRS): the issuer is a CNPJ.
      def check_no_ie_tax_id
        return unless @inf["emit"]["CNPJ"].to_s.strip.empty?

        add "emit/CNPJ: an issuer without state registration is identified by CNPJ, not CPF (RV C17-43, NT 2026.007, rej. 157)"
      end

      # RV C18-50 (rej. 158, SVRS): no IEST.
      def check_no_ie_substitute
        return if @inf["emit"]["IEST"].to_s.strip.empty?

        add "emit/IEST: an issuer without state registration can't give the tax substitute's IE (RV C18-50, NT 2026.007, rej. 158)"
      end

      # RV N01-10 (rej. 161, SVRS): no ICMS and no interstate ICMS, but on a return (finNFe 4)
      # and the credit note of type 03 (return for refusal), whose ICMS is the sale's.
      def check_no_ie_icms(item, number)
        return if @ide["finNFe"].to_s == "4" || (@ide["finNFe"].to_s == "5" && credit_note_type == "03")

        imposto = item["imposto"] || {}
        %w[ICMS ICMSUFDest].each do |group|
          next unless imposto[group]

          add "det[#{number}]/imposto/#{group}: an issuer without state registration can't carry ICMS, only IBS/CBS " \
            "(RV N01-10, NT 2026.007, rej. 161)"
        end
      end

      # RV UB12-11 (rej. 162, SVRS): the IBS/CBS group, with no exception.
      def check_no_ie_ibs_cbs(item, number)
        return if item.dig("imposto", "IBSCBS")

        add "det[#{number}]/imposto/IBSCBS: an issuer without state registration carries IBS/CBS on every item " \
          "(RV UB12-11, NT 2026.007, rej. 162)"
      end
    end
  end
end
