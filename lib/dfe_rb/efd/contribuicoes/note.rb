module DfeRb
  module Efd
    module Contribuicoes
      # An NF-e (modelo 55) or NFC-e (65) as the informant books it in the
      # EFD-Contribuições: the same C100 as the EFD ICMS/IPI's, with the PIS and COFINS of
      # its items as booked; an NF-e's items in C170, with their CST, base, rate and value
      # of each contribution and the account they go to; an NFC-e's in C175, summed by
      # CFOP, CSTs and rates (Analytic.c175).
      #
      #   note = Note.new(xml, informant: "12345678000195")
      #   items = note.items
      #   items = items.map { it.contributions(cst: "50", base: 1000, pis_rate: 1.65, cofins_rate: 7.6) } unless note.own?
      #   c100 = c010.add("C100", note.c100(items:, participant: note.participant[:cod_part], entry_date:))
      #   items.each { c100.add("C170", note.c170(it, cod_item: it.code, account: "3.1.1.01")) }
      class Note < IcmsIpi::Note
        # The C100 of the note: the identity alone for a canceled or denied one, which
        # the file may also leave out (Guia Prático, C100).
        def c100(situation: "00", items: self.items, participant: nil, entry_date: nil, period_end: nil)
          values = super
          return values if REDUCED.include?(situation)

          values.merge(vl_pis: Analytic.sum(items, &:pis_value), vl_cofins: Analytic.sum(items, &:cofins_value))
        end

        # C170 of an item of an NF-e, in the informant's code and unit, with the account
        # (COD_CTA of 0500) its revenue or credit goes to.
        def c170(item, cod_item:, unit: item.unit, quantity: item.quantity, moved: true, account: nil)
          super(item, cod_item:, unit:, quantity:, moved:).except(:vl_abat_nt)
            .merge(Analytic.contributions(item), cod_cta: account)
        end
      end

      # The items of a note summed for the EFD-Contribuições.
      module Analytic
        ZERO = BigDecimal(0)

        module_function

        # C175: an NFC-e's items summed by CFOP, CST and rate of each contribution.
        def c175(items, account: nil)
          items.group_by { |i| [i.cfop, i.pis_cst, i.pis_rate, i.pis_unit_rate, i.cofins_cst, i.cofins_rate, i.cofins_unit_rate] }
            .sort_by { |key, _| key.map(&:to_s) }.map do |_, group|
              summed = group.first.with(value: sum(group, &:value), discount: sum(group, &:discount),
                pis_base: sum(group, &:pis_base), pis_quantity: sum(group, scale: 3, &:pis_quantity), pis_value: sum(group, &:pis_value),
                cofins_base: sum(group, &:cofins_base), cofins_quantity: sum(group, scale: 3, &:cofins_quantity), cofins_value: sum(group, &:cofins_value))
              {cfop: summed.cfop, vl_opr: summed.value, vl_desc: summed.discount}.merge(contributions(summed)).merge(cod_cta: account)
            end
        end

        # The fields of each contribution of an item (C170, C175): a base in quantity
        # with its rate in reais, or else in value with its rate in percent; none for a
        # CST without either.
        def contributions(item)
          %i[pis cofins].each_with_object({}) do |tax, values|
            quantity = item.public_send(:"#{tax}_quantity")
            unit_rate = item.public_send(:"#{tax}_unit_rate")
            base = item.public_send(:"#{tax}_base")
            rate = item.public_send(:"#{tax}_rate")
            by_quantity = quantity.positive? && unit_rate.positive?
            by_value = !by_quantity && (base.positive? || rate.positive?)
            values[:"cst_#{tax}"] = item.public_send(:"#{tax}_cst")
            values[:"vl_bc_#{tax}"] = (base if by_value)
            values[:"aliq_#{tax}"] = (rate if by_value)
            values[:"quant_bc_#{tax}"] = (quantity if by_quantity)
            values[:"aliq_#{tax}_quant"] = (unit_rate if by_quantity)
            values[:"vl_#{tax}"] = item.public_send(:"#{tax}_value")
          end
        end

        def sum(items, scale: 2, &block) = items.sum(ZERO) { |i| block.call(i).round(scale) }
      end
    end
  end
end
