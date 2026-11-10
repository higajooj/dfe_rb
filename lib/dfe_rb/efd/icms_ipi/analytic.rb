module DfeRb
  module Efd
    module IcmsIpi
      # An item of a note as Block C books it. Read from the document (Item.from), the
      # values are the issuer's; on_entry turns them into what the recipient books.
      #
      # The FCP goes with the ICMS it is charged with: icms_value carries vFCP and
      # st_value vFCPST, as the file has no fields of their own for them.
      class Item
        ATTRIBUTES = %i[number code description quantity unit value discount freight insurance other cfop origin cst csosn
          icms_base icms_rate icms_value reduction_rate st_base st_rate st_value ipi_cst ipi_base ipi_rate ipi_value
          extra pis_cst cofins_cst simples_credit_rate simples_credit_value].freeze
        ZERO = BigDecimal(0)

        attr_reader(*ATTRIBUTES)

        # Of a det group of the note.
        def self.from(det)
          at = ->(path) { det.at_css(path)&.text&.strip.then { |t| t unless t.nil? || t.empty? } }
          num = ->(path) { BigDecimal(at.call(path) || "0") }
          icms = det.at_css("imposto ICMS")&.element_children&.first
          icms_at = ->(name) { icms&.at_css(name)&.text }
          icms_num = ->(name) { BigDecimal(icms_at.call(name) || "0") }
          deson = (icms_at.call("indDeduzDeson") == "1") ? icms_num.call("vICMSDeson") : ZERO
          new(
            number: det["nItem"].to_i, code: at.call("prod cProd"), description: at.call("prod xProd"),
            quantity: num.call("prod qCom"), unit: at.call("prod uCom"), value: num.call("prod vProd"), discount: num.call("prod vDesc"),
            freight: num.call("prod vFrete"), insurance: num.call("prod vSeg"), other: num.call("prod vOutro"), cfop: at.call("prod CFOP"),
            origin: icms_at.call("orig") || "0", cst: icms_at.call("CST"), csosn: icms_at.call("CSOSN"),
            icms_base: icms_num.call("vBC"), icms_rate: icms_num.call("pICMS"), icms_value: icms_num.call("vICMS") + icms_num.call("vFCP"),
            reduction_rate: icms_num.call("pRedBC"), st_base: icms_num.call("vBCST"), st_rate: icms_num.call("pICMSST"),
            st_value: icms_num.call("vICMSST") + icms_num.call("vFCPST"),
            ipi_cst: at.call("imposto IPI IPITrib CST") || at.call("imposto IPI IPINT CST"), ipi_base: num.call("imposto IPI IPITrib vBC"),
            ipi_rate: num.call("imposto IPI IPITrib pIPI"), ipi_value: num.call("imposto IPI IPITrib vIPI"),
            # What else the note's total carries for the item: the IPI given back, the import tax, less a
            # desoneração deducted from it.
            extra: num.call("impostoDevol IPI vIPIDevol") + num.call("imposto II vII") - deson,
            pis_cst: at.call("imposto PIS CST"), cofins_cst: at.call("imposto COFINS CST"),
            simples_credit_rate: icms_num.call("pCredSN"), simples_credit_value: icms_num.call("vCredICMSSN")
          )
        end

        def initialize(**attributes)
          unknown = attributes.keys - ATTRIBUTES
          raise ArgumentError, "unknown item attributes #{unknown.join(", ")}" if unknown.any?

          ATTRIBUTES.each { |a| instance_variable_set(:"@#{a}", attributes[a]) }
          %i[quantity value discount freight insurance other icms_base icms_rate icms_value reduction_rate st_base st_rate st_value
            ipi_base ipi_rate ipi_value extra simples_credit_rate simples_credit_value].each do |name|
            instance_variable_set(:"@#{name}", BigDecimal((instance_variable_get(:"@#{name}") || 0).to_s))
          end
        end

        def to_h = ATTRIBUTES.to_h { |a| [a, public_send(a)] }

        # A copy with some attributes changed.
        def with(**changes) = self.class.new(**to_h.merge(changes))

        # CST_ICMS: the origin and the CST (Tabela A and B), or the CSOSN of a note
        # issued by a company of the Simples Nacional, as it books its own.
        def cst_icms = cst ? "#{origin}#{cst}" : csosn

        # VL_OPR: the goods with freight, insurance and other expenses, the ICMS-ST and
        # its FCP and the IPI, less the discount (Guia Prático, C190 field 05).
        def operation_value = value + freight + insurance + other - discount + st_value + ipi_value + extra

        # VL_RED_BC: what the reduction of the ICMS base left untaxed, for a CST 20 or 70.
        def reduced_base
          return ZERO unless reduction_rate.positive? && reduction_rate < 100 && icms_base.positive?

          (icms_base * 100 / (100 - reduction_rate) - icms_base).round(2)
        end

        # The item as its recipient books it: in its own CFOP of entry; with the ICMS it
        # takes as credit (none, or the amount: the base and rate stay the document's,
        # or the Simples Nacional supplier's credit rate over the goods); the IPI and the
        # ST it takes no credit for added to the item's value, as part of its cost (Guia
        # Prático, C100, informação adicional 3); in the CST under its own view: ICMS
        # already charged by ST is 60, and a Simples Nacional supplier's note 90, or 60
        # when it charged ST.
        def on_entry(cfop:, icms_credit: ZERO, ipi_credit: false, st_credit: false, cst: nil)
          credit = BigDecimal(icms_credit.to_s)
          changes = {cfop:, cst: cst || entry_cst, csosn: nil}
          if credit.positive?
            base = icms_base.positive? ? icms_base : value - discount
            rate = icms_rate.positive? ? icms_rate : simples_credit_rate
            changes.merge!(icms_base: base, icms_rate: rate, icms_value: credit)
          else
            changes.merge!(icms_base: ZERO, icms_rate: ZERO, icms_value: ZERO, reduction_rate: ZERO)
          end
          folded = value
          unless ipi_credit
            folded += ipi_value
            changes.merge!(ipi_base: ZERO, ipi_rate: ZERO, ipi_value: ZERO)
          end
          unless st_credit
            folded += st_value
            changes.merge!(st_base: ZERO, st_rate: ZERO, st_value: ZERO)
          end
          with(**changes, value: folded)
        end

        # A recipient's CST for the item, without the origin.
        def entry_cst
          return (%w[201 202 203 500].include?(csosn) ? "60" : "90") if csosn
          return "60" if %w[10 30 70].include?(cst)

          cst || "90"
        end
      end

      # The analytic records of a note (C190): its items summed by CST_ICMS, CFOP and ICMS
      # rate; and the totals of its C100, which add up its C190.
      module Analytic
        ZERO = BigDecimal(0)

        module_function

        def c190(items)
          items.group_by { |i| [i.cst_icms, i.cfop, rate(i)] }.sort_by(&:first).map do |(cst, cfop, aliq), group|
            {
              cst_icms: cst, cfop:, aliq_icms: aliq, vl_opr: sum(group, &:operation_value), vl_bc_icms: sum(group, &:icms_base),
              vl_icms: sum(group, &:icms_value), vl_bc_icms_st: sum(group, &:st_base), vl_icms_st: sum(group, &:st_value),
              vl_red_bc: sum(group, &:reduced_base), vl_ipi: sum(group, &:ipi_value)
            }
          end
        end

        def totals(items)
          {
            value: sum(items, &:value), discount: sum(items, &:discount), freight: sum(items, &:freight), insurance: sum(items, &:insurance),
            other: sum(items, &:other), icms_base: sum(items, &:icms_base), icms_value: sum(items, &:icms_value), st_base: sum(items, &:st_base),
            st_value: sum(items, &:st_value), ipi_value: sum(items, &:ipi_value), operation_value: sum(items, &:operation_value)
          }
        end

        # The rate of an item that has ICMS; zero for one that has none.
        def rate(item) = item.icms_value.positive? ? item.icms_rate : ZERO

        def sum(items, &block) = items.sum(ZERO) { |i| block.call(i).round(2) }
      end
    end
  end
end
