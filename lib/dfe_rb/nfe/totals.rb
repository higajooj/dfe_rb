require "bigdecimal"

module DfeRb
  module Nfe
    # Derives the invoice totals (<total>) from the items, following the sums the validation
    # rules of Anexo I §W require. Tax values themselves are never computed: they come from
    # the items.
    module Totals
      ZERO = BigDecimal(0)

      ICMS_BASE = %w[ICMS00 ICMS10 ICMS20 ICMS51 ICMS70 ICMS90 ICMSPart ICMSSN900].freeze
      ICMS_ST = %w[ICMS10 ICMS30 ICMS70 ICMS90 ICMSPart ICMSSN201 ICMSSN202 ICMSSN900].freeze
      ICMS_FCP = %w[ICMS00 ICMS10 ICMS20 ICMS51 ICMS70 ICMS90].freeze
      ICMS_FCP_ST = %w[ICMS10 ICMS30 ICMS70 ICMS90 ICMSPart ICMSSN201 ICMSSN202 ICMSSN900].freeze
      ICMS_FCP_ST_RET = %w[ICMS60 ICMSST ICMSSN500].freeze
      ICMS_EXEMPTION = %w[ICMS20 ICMS30 ICMS40 ICMS70 ICMS90 ICMSPart].freeze

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

      def sum(items)
        items.sum(ZERO) { |item| number(yield(item)) }
      end

      def icms_variant(item)
        icms = item.dig("imposto", "ICMS") || {}
        icms.first
      end

      # Sum of `tag` over the items whose ICMS variant is in `variants`.
      def icms_sum(items, variants, tag)
        sum(items) do |item|
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

        destination = items.filter_map { |item| item.dig("imposto", "ICMSUFDest") }
        unless destination.empty?
          total["vFCPUFDest"] = sum(destination) { |d| d["vFCPUFDest"] }
          total["vICMSUFDest"] = sum(destination) { |d| d["vICMSUFDest"] }
          total["vICMSUFRemet"] = sum(destination) { |d| d["vICMSUFRemet"] }
        end

        total["vNF"] = invoice_amount(total, deduct_exemption: exemption_deducted?(items))
        total.transform_values { |value| money(value) }
      end

      # vNF as RV W16-10 defines it. (IBS/CBS/IS are "por fora" and stay out in 2026.)
      def invoice_amount(total, deduct_exemption: false)
        amount = number(total["vProd"]) - number(total["vDesc"]) + number(total["vST"]) + number(total["vFCPST"]) +
          number(total["vFrete"]) + number(total["vSeg"]) + number(total["vOutro"]) + number(total["vII"]) +
          number(total["vIPI"]) + number(total["vIPIDevol"])
        amount -= number(total["vICMSDeson"]) if deduct_exemption
        amount
      end

      def exemption_deducted?(items)
        items.any? do |item|
          _name, values = icms_variant(item)
          values && values["indDeduzDeson"].to_s == "1"
        end
      end

      # IBSCBSTot for the items carrying a normal-tax <gIBSCBS> group, or nil.
      def ibs_cbs_total(items)
        groups = items.filter_map { |item| item.dig("imposto", "IBSCBS", "gIBSCBS") }
        return if groups.empty?

        part = ->(*path) { sum(groups) { |group| group.dig(*path) } }
        credit = ->(tag, side) { sum(items) { |item| item.dig("imposto", "IBSCBS", "gCredPresOper", side, tag) } }

        {
          "vBCIBSCBS" => money(part.call("vBC")),
          "gIBS" => {
            "gIBSUF" => {"vDif" => money(part.call("gIBSUF", "gDif", "vDif")),
                         "vDevTrib" => money(part.call("gIBSUF", "gDevTrib", "vDevTrib")),
                         "vIBSUF" => money(part.call("gIBSUF", "vIBSUF"))},
            "gIBSMun" => {"vDif" => money(part.call("gIBSMun", "gDif", "vDif")),
                          "vDevTrib" => money(part.call("gIBSMun", "gDevTrib", "vDevTrib")),
                          "vIBSMun" => money(part.call("gIBSMun", "vIBSMun"))},
            "vIBS" => money(part.call("vIBS")),
            "vCredPres" => money(credit.call("vCredPres", "gIBSCredPres")),
            "vCredPresCondSus" => money(credit.call("vCredPresCondSus", "gIBSCredPres"))
          },
          "gCBS" => {
            "vDif" => money(part.call("gCBS", "gDif", "vDif")),
            "vDevTrib" => money(part.call("gCBS", "gDevTrib", "vDevTrib")),
            "vCBS" => money(part.call("gCBS", "vCBS")),
            "vCredPres" => money(credit.call("vCredPres", "gCBSCredPres")),
            "vCredPresCondSus" => money(credit.call("vCredPresCondSus", "gCBSCredPres"))
          }
        }
      end
    end
  end
end
