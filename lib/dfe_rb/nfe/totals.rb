require "bigdecimal"

module DfeRb
  module Nfe
    # Derives the invoice totals (<total>) from the items, following the sums the validation
    # rules of Anexo I §W require. Tax values themselves are never computed here. They come
    # from the items.
    #
    # Item values are rounded as the XML will show them before they are added, so a total
    # always matches the sum of what the recipient (and SEFAZ) reads.
    module Totals
      ZERO = BigDecimal(0)

      ICMS_BASE = %w[ICMS00 ICMS10 ICMS20 ICMS51 ICMS70 ICMS90 ICMSPart ICMSSN900].freeze
      ICMS_ST = %w[ICMS10 ICMS30 ICMS70 ICMS90 ICMSPart ICMSSN201 ICMSSN202 ICMSSN900].freeze
      ICMS_FCP = %w[ICMS00 ICMS10 ICMS20 ICMS51 ICMS70 ICMS90].freeze
      ICMS_FCP_ST = %w[ICMS10 ICMS30 ICMS70 ICMS90 ICMSPart ICMSSN201 ICMSSN202 ICMSSN900].freeze
      ICMS_FCP_ST_RET = %w[ICMS60 ICMSST ICMSSN500].freeze
      ICMS_EXEMPTION = %w[ICMS20 ICMS30 ICMS40 ICMS70 ICMS90 ICMSPart].freeze
      # Monophase fuel taxation (NT 2023.001): each tag exists only in the variants that carry it.
      ICMS_MONO = %w[ICMS02 ICMS15 ICMS53 ICMS61].freeze
      MONO_TAGS = %w[qBCMono vICMSMono qBCMonoReten vICMSMonoReten qBCMonoRet vICMSMonoRet].freeze
      QUANTITY_PLACES = 4
      # Faturamento direto de veículos novos (veicProd/tpOp).
      DIRECT_VEHICLE_SALE = "2"
      # From this year IBS, CBS and IS enter vItem (RV VB01-10, exceção 1).
      IBS_CBS_IN_TOTAL_SINCE = 2027

      module_function

      # A BigDecimal for any numeric-looking value; nil, blanks and junk count as zero (the
      # writer reports junk on the field itself).
      def number(value)
        return ZERO if value.nil? || value == ""

        value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
      rescue ArgumentError, TypeError
        ZERO
      end

      def money(value) = number(value).round(2, half: :up)

      # Sum of the values the block picks, each rounded to `places` as the XML writes it.
      def sum(items, places: 2)
        items.sum(ZERO) { |item| number(yield(item)).round(places, half: :up) }
      end

      def icms_variant(item)
        icms = item.dig("imposto", "ICMS") || {}
        icms.first
      end

      # Sum of `tag` over the items whose ICMS variant is in `variants`.
      def icms_sum(items, variants, tag, places: 2)
        sum(items, places: places) do |item|
          name, values = icms_variant(item)
          (name && variants.include?(name)) ? values[tag] : nil
        end
      end

      def contribution_sum(items, group, tag)
        sum(items) do |item|
          entry = item.dig("imposto", group)
          entry&.values&.first&.[](tag)
        end
      end

      # The ICMSTot values for `items` (each a resolved <det> hash).
      def icms_total(items)
        prod = ->(tag) { sum(items) { |item| item.dig("prod", tag) } }
        counted = items.select { |item| item.dig("prod", "indTot").to_s != "0" }

        total = {
          "vBC" => icms_sum(items, ICMS_BASE, "vBC"),
          "vICMS" => icms_sum(items, ICMS_BASE, "vICMS"),
          "vICMSDeson" => icms_sum(items, ICMS_EXEMPTION, "vICMSDeson"),
          "vFCP" => icms_sum(items, ICMS_FCP, "vFCP"),
          "vBCST" => icms_sum(items, ICMS_ST, "vBCST"),
          "vST" => icms_sum(items, ICMS_ST, "vICMSST"),
          "vFCPST" => icms_sum(items, ICMS_FCP_ST, "vFCPST"),
          "vFCPSTRet" => icms_sum(items, ICMS_FCP_ST_RET, "vFCPSTRet"),
          "vProd" => sum(counted) { |item| item.dig("prod", "vProd") },
          "vFrete" => prod.call("vFrete"),
          "vSeg" => prod.call("vSeg"),
          "vDesc" => prod.call("vDesc"),
          "vII" => sum(items) { |item| item.dig("imposto", "II", "vII") },
          "vIPI" => sum(items) { |item| item.dig("imposto", "IPI", "IPITrib", "vIPI") },
          "vIPIDevol" => sum(items) { |item| item.dig("impostoDevol", "IPI", "vIPIDevol") },
          "vPIS" => contribution_sum(items, "PIS", "vPIS"),
          "vCOFINS" => contribution_sum(items, "COFINS", "vCOFINS"),
          "vOutro" => prod.call("vOutro")
        }

        if items.any? { |item| ICMS_MONO.include?(icms_variant(item)&.first) }
          MONO_TAGS.each do |tag|
            total[tag] = icms_sum(items, ICMS_MONO, tag, places: tag.start_with?("q") ? QUANTITY_PLACES : 2)
          end
        end

        destination = items.filter_map { |item| item.dig("imposto", "ICMSUFDest") }
        unless destination.empty?
          total["vFCPUFDest"] = sum(destination) { |d| d["vFCPUFDest"] }
          total["vICMSUFDest"] = sum(destination) { |d| d["vICMSUFDest"] }
          total["vICMSUFRemet"] = sum(destination) { |d| d["vICMSUFRemet"] }
        end

        total["vNF"] = invoice_amount(total, items)
        total.transform_values { |value| money(value) }
      end

      # vNF as RV W16-10 defines it (NT 2023.001 v1.60). IBS, CBS and IS are "por fora" and
      # stay out of it in 2026.
      def invoice_amount(total, items)
        amount = number(total["vProd"]) - number(total["vDesc"]) + number(total["vFrete"]) + number(total["vSeg"]) +
          number(total["vOutro"]) + number(total["vII"]) + number(total["vIPI"]) + number(total["vIPIDevol"])
        amount -= deducted_exemption(items)
        amount += sum(items) { |item| item.dig("imposto", "PISST", "vPIS") if item.dig("imposto", "PISST", "indSomaPISST").to_s == "1" }
        amount += sum(items) do |item|
          item.dig("imposto", "COFINSST", "vCOFINS") if item.dig("imposto", "COFINSST", "indSomaCOFINSST").to_s == "1"
        end
        return amount if direct_vehicle_sale?(items)

        amount + number(total["vST"]) + number(total["vFCPST"]) + number(total["vICMSMonoReten"])
      end

      # vICMSDeson of the items that flag it as deducted from their value (indDeduzDeson=1).
      def deducted_exemption(items)
        sum(items) do |item|
          name, values = icms_variant(item)
          values["vICMSDeson"] if ICMS_EXEMPTION.include?(name) && values["indDeduzDeson"].to_s == "1"
        end
      end

      def direct_vehicle_sale?(items)
        items.any? { |item| item.dig("prod", "veicProd", "tpOp").to_s == DIRECT_VEHICLE_SALE }
      end

      # vItem, the item's share of the invoice total (RV VB01-10, VB01-20). IBS, CBS and IS
      # are "por fora" and only count from 2027.
      def item_amount(item, year)
        prod = item["prod"] || {}
        imposto = item["imposto"] || {}
        name, icms = icms_variant(item)
        icms ||= {}
        pick = ->(variants, tag) { (name && variants.include?(name)) ? number(icms[tag]).round(2, half: :up) : ZERO }
        money_of = ->(value) { number(value).round(2, half: :up) }

        amount = %w[vProd vFrete vSeg vOutro].sum(ZERO) { |tag| money_of.call(prod[tag]) } - money_of.call(prod["vDesc"])
        amount -= pick.call(ICMS_EXEMPTION, "vICMSDeson") if icms["indDeduzDeson"].to_s == "1"
        amount += money_of.call(imposto.dig("II", "vII")) + money_of.call(imposto.dig("IPI", "IPITrib", "vIPI")) +
          money_of.call(item.dig("impostoDevol", "IPI", "vIPIDevol"))
        %w[PIS COFINS].each do |tax|
          st = imposto["#{tax}ST"]
          amount += money_of.call(st["v#{tax}"]) if st && st["indSoma#{tax}ST"].to_s == "1"
        end
        unless direct_vehicle_sale?([item])
          amount += pick.call(ICMS_ST, "vICMSST") + pick.call(ICMS_FCP_ST, "vFCPST") + pick.call(ICMS_MONO, "vICMSMonoReten")
        end
        if year && year >= IBS_CBS_IN_TOTAL_SINCE
          group = imposto.dig("IBSCBS", "gIBSCBS") || {}
          mono = imposto.dig("IBSCBS", "gIBSCBSMono") || {}
          amount += money_of.call(group["vIBS"]) + money_of.call(group.dig("gCBS", "vCBS")) + money_of.call(imposto.dig("IS", "vIS"))
          amount += money_of.call(mono["vTotIBSMonoItem"]) + money_of.call(mono["vTotCBSMonoItem"]) unless direct_vehicle_sale?([item])
        end
        money(amount)
      end

      # ISTot, required once any item carries <IS> (RV W31-20), or nil.
      def selective_total(items)
        taxed = items.filter_map { |item| item.dig("imposto", "IS") }
        return if taxed.empty?

        {"vIS" => money(sum(taxed) { |group| group["vIS"] })}
      end

      # IBSCBSTot, required once any item carries <IBSCBS> (RV W34-20), or nil. The IBS/CBS,
      # monophase and credit-reversal groups appear only when some item has them.
      def ibs_cbs_total(items)
        taxed = items.filter_map { |item| item.dig("imposto", "IBSCBS") }
        return if taxed.empty?

        groups = taxed.filter_map { |ibscbs| ibscbs["gIBSCBS"] }
        part = ->(*path) { sum(groups) { |group| group.dig(*path) } }
        credit = ->(tag, side) { sum(taxed) { |ibscbs| ibscbs.dig("gCredPresOper", side, tag) } }

        total = {"vBCIBSCBS" => money(part.call("vBC"))}
        unless groups.empty?
          total["gIBS"] = {
            "gIBSUF" => {"vDif" => money(part.call("gIBSUF", "gDif", "vDif")),
                         "vDevTrib" => money(part.call("gIBSUF", "gDevTrib", "vDevTrib")),
                         "vIBSUF" => money(part.call("gIBSUF", "vIBSUF"))},
            "gIBSMun" => {"vDif" => money(part.call("gIBSMun", "gDif", "vDif")),
                          "vDevTrib" => money(part.call("gIBSMun", "gDevTrib", "vDevTrib")),
                          "vIBSMun" => money(part.call("gIBSMun", "vIBSMun"))},
            "vIBS" => money(part.call("vIBS")),
            "vCredPres" => money(credit.call("vCredPres", "gIBSCredPres")),
            "vCredPresCondSus" => money(credit.call("vCredPresCondSus", "gIBSCredPres"))
          }
          total["gCBS"] = {
            "vDif" => money(part.call("gCBS", "gDif", "vDif")),
            "vDevTrib" => money(part.call("gCBS", "gDevTrib", "vDevTrib")),
            "vCBS" => money(part.call("gCBS", "vCBS")),
            "vCredPres" => money(credit.call("vCredPres", "gCBSCredPres")),
            "vCredPresCondSus" => money(credit.call("vCredPresCondSus", "gCBSCredPres"))
          }
        end

        mono = taxed.filter_map { |ibscbs| ibscbs["gIBSCBSMono"] }
        unless mono.empty?
          total["gMono"] = %w[vIBSMono vCBSMono vIBSMonoReten vCBSMonoReten vIBSMonoRet vCBSMonoRet].to_h do |tag|
            [tag, money(mono.sum(ZERO) { |group| nested_sum(group, tag) })]
          end
        end

        reversals = taxed.filter_map { |ibscbs| ibscbs["gEstornoCred"] }
        unless reversals.empty?
          total["gEstornoCred"] = %w[vIBSEstCred vCBSEstCred].to_h { |tag| [tag, money(sum(reversals) { |group| group[tag] })] }
        end
        total
      end

      # Sum of every `tag` anywhere inside `data` (the monophase group nests its values by
      # ad rem / ad valorem and by kind).
      def nested_sum(data, tag)
        case data
        when Hash then data.sum(ZERO) { |key, value| (key == tag) ? number(value).round(2, half: :up) : nested_sum(value, tag) }
        when Array then data.sum(ZERO) { |value| nested_sum(value, tag) }
        else ZERO
        end
      end
    end
  end
end
