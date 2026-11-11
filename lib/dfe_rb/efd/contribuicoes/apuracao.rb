module DfeRb
  module Efd
    module Contribuicoes
      # The apuração of one contribution (PIS or COFINS) for Block M and the control of
      # its credits in Block 1, as the Guia Prático's validations state them: the
      # contribution of each code and rate (M210, M610) from the revenues booked in Block
      # C, with the adjustments of its base (M215) and of itself (M220); the credits of
      # each type (M100, M500) from the bases booked, less their reductions (M110); the
      # credits of the months before spent first, oldest first, then those of the
      # month; what is left to pay (M200, M205); the revenues without the contribution
      # by CST and nature (M400, M410); and each month's credit left (1100, 1500).
      #
      #   pis = Apuracao.new(:pis, regime: :non_cumulative, cnpj: "12345678000195", month: Date.new(2026, 1, 1))
      #   pis.revenue(cst: "01", rate: 1.65, revenue: 1000, base: 1000, account: "3.1.1.01")
      #   pis.untaxed(cst: "04", nature: "002", revenue: 200)
      #   pis.credit(cst: "50", nature: "01", base: 600, rate: 1.65)
      #   pis.carried = [{month: Date.new(2025, 12, 1), code: "101", apurado: 30, balance: 12}]
      #   pis.write(file)
      #   pis.carry   # what the next month starts from
      class Apuracao
        ZERO = BigDecimal(0)
        TAXES = %i[pis cofins].freeze
        # The basic rates (COD_CRED x01, COD_CONT 01 and 51).
        BASIC_RATES = {pis: {non_cumulative: BigDecimal("1.65"), cumulative: BigDecimal("0.65")},
                       cofins: {non_cumulative: BigDecimal("7.6"), cumulative: BigDecimal(3)}}.freeze
        # The DCTF's codes of what is owed (COD_REC of M205 and M605, six digits): the
        # DARF's code and its variation.
        REVENUE_CODES = {pis: {non_cumulative: "691201", cumulative: "810902"},
                         cofins: {non_cumulative: "585601", cumulative: "217201"}}.freeze
        # The registers of the PIS, and the COFINS's that stand for them.
        REGISTERS = {"M100" => "M500", "M105" => "M505", "M110" => "M510", "M200" => "M600", "M205" => "M605", "M210" => "M610",
                     "M215" => "M615", "M220" => "M620", "M400" => "M800", "M410" => "M810", "1100" => "1500"}.freeze
        # The entry CSTs of a credit, by the revenues it goes with: taxed in the country
        # (1xx), untaxed (2xx), exports (3xx).
        CREDIT_GROUPS = {"50" => %i[taxed], "51" => %i[untaxed], "52" => %i[export], "53" => %i[taxed untaxed], "54" => %i[taxed export],
                         "55" => %i[untaxed export], "56" => %i[taxed untaxed export]}.freeze
        GROUP_DIGITS = {taxed: "1", untaxed: "2", export: "3"}.freeze
        NON_CUMULATIVE_CODES = %w[01 02 03 04 32 71].freeze
        # CST 05 (by ST) isn't among them: since PGE 2.0.5 it goes in M210 and M610, even at a
        # zero rate (Guia Prático, M400).
        UNTAXED_CSTS = %w[04 06 07 08 09].freeze

        attr_reader :tax, :regime, :cnpj, :month
        # Credits of the months before: [{month:, code:, apurado:, balance:}], apurado
        # being what the month made available (VL_CRED_DISP) and balance what is left.
        attr_accessor :carried

        # regime is :non_cumulative or :cumulative; shares, for credits that go with more
        # than one kind of revenue (CST 53 to 56), the month's gross revenue of each
        # ({taxed:, untaxed:, export:}, as 0111 gives it).
        def initialize(tax, regime:, cnpj:, month:, shares: nil)
          raise ArgumentError, "unknown contribution #{tax.inspect} (use #{TAXES.join(", ")})" unless TAXES.include?(tax)
          raise ArgumentError, "unknown regime #{regime.inspect}" unless %i[non_cumulative cumulative].include?(regime)

          @tax = tax
          @regime = regime
          @cnpj = cnpj
          @month = month
          @shares = shares
          @revenues = []
          @untaxed = []
          @credits = []
          @credit_reductions = []
          @base_reductions = []
          @carried = []
        end

        # A revenue taxed (CST 01 to 03, or 05 by ST, code 31, even at a zero rate), at a
        # rate in percent: its gross revenue and base.
        def revenue(cst:, rate:, revenue:, base:)
          @revenues << {code: contribution_code(cst, rate), rate: d(rate), revenue: d(revenue), base: d(base)}
        end

        # A revenue without the contribution (CST 04 to 09), by its nature (NAT_REC of
        # tables 4.3.10 to 4.3.16).
        def untaxed(cst:, nature:, revenue:, account: nil)
          raise ArgumentError, "CST #{cst} isn't of a revenue without the contribution" unless UNTAXED_CSTS.include?(cst)

          @untaxed << {cst:, nature:, revenue: d(revenue), account:}
        end

        # The base of a credit (entry CST 50 to 56), of a nature (NAT_BC_CRED, table
        # 4.3.7), at a rate in percent.
        def credit(cst:, nature:, base:, rate:)
          raise ArgumentError, "CST #{cst} isn't of a credit" unless CREDIT_GROUPS.key?(cst)

          @credits << {cst:, nature:, base: d(base), rate: d(rate)}
        end

        # A credit taken back (M110, a reduction): of the credit type it was taken as, or
        # of the entry CST it was taken with (a CST 53 to 56 is split by the month's shares
        # of each revenue, at the rate given), with the document and the day it refers to.
        # What exceeds the month's credit of that type is added to the contribution (M220).
        def reduce_credit(amount:, type: nil, cst: nil, rate: nil, code: "06", document: nil, description: nil, date: nil)
          details = {code:, document:, description:, date:}
          return @credit_reductions << details.merge(type:, amount: d(amount)) if type
          raise ArgumentError, "CST #{cst.inspect} isn't of a credit" unless CREDIT_GROUPS.key?(cst)

          groups = CREDIT_GROUPS.fetch(cst)
          weights = split(groups)
          digit = (rate.nil? || d(rate) == BASIC_RATES.dig(tax, :non_cumulative)) ? "01" : "02"
          parts = groups.map { |group| [group, round(d(amount) * weights.fetch(group))] }
          parts[-1][1] += d(amount) - parts.sum { |_, part| part }
          parts.each do |group, part|
            @credit_reductions << details.merge(type: "#{GROUP_DIGITS.fetch(group)}#{digit}", amount: part) if part.positive?
          end
        end

        # A reduction of the base of the contribution of a CST and rate (M215), coded by
        # table 4.3.18 (02: sales given back). Never below nothing.
        def reduce_base(cst:, rate:, amount:, code:, document: nil, description: nil, date: nil, account: nil)
          @base_reductions << {code: contribution_code(cst, rate), rate: d(rate), amount: d(amount), adjustment: code, document:, description:,
                               date:, account:}
        end

        # The records of the apuração, worked out once.
        def result = @result ||= work_out

        # Adds M100 to M410 (or M500 to M810) and 1100 (or 1500) to the file.
        def write(file)
          r = result
          r[:credits].each do |credit|
            m100 = file.add(code("M100"), credit[:values])
            credit[:details].each { m100.add(code("M105"), _1) }
            credit[:reductions].each { m100.add(code("M110"), _1) }
          end
          m200 = file.add(code("M200"), r[:m200])
          r[:m205].each { m200.add(code("M205"), _1) }
          r[:contributions].each do |contribution|
            m210 = m200.add(code("M210"), contribution[:values])
            contribution[:base_adjustments].each { m210.add(code("M215"), _1) }
            contribution[:adjustments].each { m210.add(code("M220"), _1) }
          end
          r[:untaxed].each do |group|
            m400 = file.add(code("M400"), group[:values])
            group[:details].each { m400.add(code("M410"), _1) }
          end
          r[:control].each { file.add(code("1100"), _1) }
          file
        end

        # The credits the next month starts from: [{month:, code:, apurado:, balance:}].
        def carry = result[:carry]

        # What is left to pay of the contribution in the month.
        def payable = result[:m200][:vl_tot_cont_rec]

        def non_cumulative? = regime == :non_cumulative

        private

        def d(value) = BigDecimal((value || 0).to_s)

        def round(value) = value.round(2, BigDecimal::ROUND_HALF_UP)

        def basic_rate = BASIC_RATES.fetch(tax).fetch(regime)

        # COD_CONT (table 4.3.5): the basic rate, a different one or by quantity, in the
        # company's regime; ST is 31.
        def contribution_code(cst, rate)
          return "31" if cst == "05"

          kind = case cst
          when "03" then 3
          when "02" then 2
          else (d(rate) == basic_rate) ? 1 : 2
          end
          non_cumulative? ? "0#{kind}" : "5#{kind}"
        end

        # The register of the contribution for one of the PIS (M100: M100 or M500).
        def code(pis_code) = (tax == :pis) ? pis_code : REGISTERS.fetch(pis_code)

        # A field of the PIS's register as the contribution names it.
        def field(name)
          return name if tax == :pis
          return :vl_cred_difer if name == :vl_cred_dif

          name.to_s.sub("pis", "cofins").to_sym
        end

        def fields(hash) = hash.transform_keys { field(_1) }

        def work_out
          contributions = contribution_groups
          credits, excess = credit_groups
          # Credit taken back beyond the month's: added to the contribution at the basic rate.
          if excess.any?
            target = contributions.find { |c| c[:code] == (non_cumulative? ? "01" : "51") && c[:rate] == basic_rate } ||
              new_contribution(non_cumulative? ? "01" : "51", basic_rate).tap { contributions << _1 }
            excess.each do |reduction|
              target[:increase] += reduction[:amount]
              target[:adjustments] << {ind_aj: "1", vl_aj: reduction[:amount], cod_aj: reduction[:code], num_doc: reduction[:document],
                                       descr_aj: reduction[:description], dt_ref: reduction[:date]}
            end
          end
          contributions.each { finish_contribution(_1) }

          owed_nc = contributions.select { NON_CUMULATIVE_CODES.include?(_1[:code]) }.sum(ZERO) { _1[:values][:vl_cont_per] }
          owed_cum = contributions.reject { NON_CUMULATIVE_CODES.include?(_1[:code]) }.sum(ZERO) { _1[:values][:vl_cont_per] }

          # The credits of the months before first, oldest first; then the month's.
          left = owed_nc
          control = []
          carry = []
          earlier = carried.select { d(_1[:balance]).positive? }.sort_by { [_1[:month], _1[:code]] }
          used_before = ZERO
          earlier.each do |entry|
            balance = d(entry[:balance])
            used = [balance, left].min
            left -= used
            used_before += used
            apurado = d(entry[:apurado])
            control << {per_apu_cred: entry[:month].strftime("%m%Y"), orig_cred: "01", cod_cred: entry[:code], vl_cred_apu: apurado, vl_cred_ext_apu: ZERO,
                        vl_tot_cred_apu: apurado, vl_cred_desc_pa_ant: apurado - balance, sd_cred_disp_efd: balance, vl_cred_desc_efd: used,
                        sld_cred_fim: balance - used}
            carry << {month: entry[:month], code: entry[:code], apurado:, balance: balance - used} if balance > used
          end
          spent = ZERO
          credits.each do |credit|
            values = credit[:values]
            available = values[:vl_cred_disp]
            used = [available, left].min
            left -= used
            spent += used
            values.merge!(ind_desc_cred: (used == available) ? "0" : "1", vl_cred_desc: used, sld_cred: available - used)
            next unless available > used

            control << {per_apu_cred: month.strftime("%m%Y"), orig_cred: "01", cod_cred: values[:cod_cred], vl_cred_apu: available, vl_cred_ext_apu: ZERO,
                        vl_tot_cred_apu: available, vl_cred_desc_pa_ant: used, sd_cred_disp_efd: available - used, vl_cred_desc_efd: ZERO,
                        sld_cred_fim: available - used}
            carry << {month:, code: values[:cod_cred], apurado: available, balance: available - used}
          end

          due_nc = owed_nc - spent - used_before
          m200 = {vl_tot_cont_nc_per: owed_nc, vl_tot_cred_desc: spent, vl_tot_cred_desc_ant: used_before, vl_tot_cont_nc_dev: due_nc, vl_ret_nc: ZERO,
                  vl_out_ded_nc: ZERO, vl_cont_nc_rec: due_nc, vl_tot_cont_cum_per: owed_cum, vl_ret_cum: ZERO, vl_out_ded_cum: ZERO,
                  vl_cont_cum_rec: owed_cum, vl_tot_cont_rec: due_nc + owed_cum}
          m205 = []
          m205 << {num_campo: "08", cod_rec: REVENUE_CODES.dig(tax, :non_cumulative), vl_debito: due_nc} if due_nc.positive?
          m205 << {num_campo: "12", cod_rec: REVENUE_CODES.dig(tax, :cumulative), vl_debito: owed_cum} if owed_cum.positive?

          {
            credits: credits.map { |c| {values: fields(c[:values]), details: c[:details].map { |detail| fields(detail) }, reductions: c[:reductions]} },
            contributions: contributions.map do |c|
              {values: fields(c[:values]), base_adjustments: c[:base_adjustments].map { |adjustment| fields(adjustment) }, adjustments: c[:adjustments]}
            end,
            m200:, m205:, untaxed: untaxed_groups, control:, carry:
          }
        end

        def new_contribution(code, rate)
          {code:, rate:, revenue: ZERO, base: ZERO, increase: ZERO, decrease: ZERO, base_adjustments: [], adjustments: []}
        end

        # M210 and M215: the revenues by COD_CONT and rate, their bases reduced.
        def contribution_groups
          groups = @revenues.group_by { [_1[:code], _1[:rate]] }.map do |(code, rate), lines|
            new_contribution(code, rate).merge(revenue: lines.sum(ZERO) { _1[:revenue] }, base: lines.sum(ZERO) { _1[:base] })
          end
          @base_reductions.each do |reduction|
            group = groups.find { |g| g[:code] == reduction[:code] && g[:rate] == reduction[:rate] }
            room = group ? group[:base] - group[:base_adjustments].sum(ZERO) { _1[:vl_aj_bc] } : ZERO
            amount = [reduction[:amount], room].min
            next unless amount.positive?

            group[:base_adjustments] << {ind_aj_bc: "0", vl_aj_bc: amount, cod_aj_bc: reduction[:adjustment], num_doc: reduction[:document],
                                         descr_aj_bc: reduction[:description], dt_ref: reduction[:date], cod_cta: reduction[:account], cnpj:}
          end
          groups.sort_by { [_1[:code], _1[:rate]] }
        end

        def finish_contribution(group)
          reduced = group[:base_adjustments].sum(ZERO) { _1[:vl_aj_bc] }
          base = group[:base] - reduced
          owed = round(base * group[:rate] / 100)
          group[:values] = {
            cod_cont: group[:code], vl_rec_brt: group[:revenue], vl_bc_cont: group[:base], vl_ajus_acres_bc_pis: ZERO, vl_ajus_reduc_bc_pis: reduced,
            vl_bc_cont_ajus: base, aliq_pis: group[:rate], vl_cont_apur: owed, vl_ajus_acres: group[:increase], vl_ajus_reduc: group[:decrease],
            vl_cont_difer: ZERO, vl_cont_difer_ant: ZERO, vl_cont_per: owed + group[:increase] - group[:decrease]
          }
        end

        # M100, M105 and M110: the credits by type and rate. A base that goes with more
        # than one kind of revenue is split by the month's shares of each.
        def credit_groups
          lines = []
          @credits.each do |credit|
            groups = CREDIT_GROUPS.fetch(credit[:cst])
            weights = split(groups)
            groups.each do |group|
              share = (groups.size == 1) ? credit[:base] : round(credit[:base] * weights.fetch(group))
              digit = (credit[:rate] == BASIC_RATES.dig(tax, :non_cumulative)) ? "01" : "02"
              lines << credit.merge(type: "#{GROUP_DIGITS.fetch(group)}#{digit}", share:)
            end
          end
          excess = []
          reductions = @credit_reductions.group_by { _1[:type] }
          credits = lines.group_by { [_1[:type], _1[:rate]] }.sort_by(&:first).map do |(type, rate), group|
            details = group.group_by { [_1[:nature], _1[:cst]] }.sort_by(&:first).map do |(nature, cst), parts|
              total = parts.sum(ZERO) { _1[:base] }
              {nat_bc_cred: nature, cst_pis: cst, vl_bc_pis_tot: total, vl_bc_pis_cum: ZERO, vl_bc_pis_nc: total, vl_bc_pis: parts.sum(ZERO) { _1[:share] }}
            end
            base = details.sum(ZERO) { _1[:vl_bc_pis] }
            amount = round(base * rate / 100)
            taken = []
            room = amount
            reductions.delete(type).to_a.each do |reduction|
              part = [reduction[:amount], room].min
              room -= part
              if part.positive?
                taken << {ind_aj: "0", vl_aj: part, cod_aj: reduction[:code], num_doc: reduction[:document], descr_aj: reduction[:description],
                          dt_ref: reduction[:date]}
              end
              excess << reduction.merge(amount: reduction[:amount] - part) if reduction[:amount] > part
            end
            reduced = taken.sum(ZERO) { _1[:vl_aj] }
            {values: {cod_cred: type, ind_cred_ori: 0, vl_bc_pis: base, aliq_pis: rate, vl_cred: amount, vl_ajus_acres: ZERO, vl_ajus_reduc: reduced,
                      vl_cred_dif: ZERO, vl_cred_disp: amount - reduced},
             details:, reductions: taken}
          end
          # Reductions of a type with no credit in the month: all of it goes to the contribution.
          reductions.each_value { |list| excess.concat(list) }
          [credits, excess]
        end

        # Each kind of revenue's share among those a credit goes with, by the month's
        # gross revenue; evenly when there was none.
        def split(groups)
          revenue = groups.to_h { [_1, d(@shares&.fetch(_1, 0))] }
          total = revenue.values.sum(ZERO)
          return groups.to_h { [_1, BigDecimal(1) / groups.size] } unless total.positive?

          revenue.transform_values { _1 / total }
        end

        # M400 and M410: the revenues without the contribution, by CST and nature.
        def untaxed_groups
          @untaxed.group_by { _1[:cst] }.sort_by(&:first).map do |cst, lines|
            details = lines.group_by { [_1[:nature], _1[:account]] }.sort_by { |key, _| key.map(&:to_s) }.map do |(nature, account), parts|
              {nat_rec: nature, vl_rec: parts.sum(ZERO) { _1[:revenue] }, cod_cta: account}
            end
            accounts = lines.map { _1[:account] }.uniq
            {values: fields(cst_pis: cst, vl_tot_rec: details.sum(ZERO) { _1[:vl_rec] }, cod_cta: (accounts.first if accounts.one?)), details:}
          end
        end
      end
    end
  end
end
