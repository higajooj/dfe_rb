require "bigdecimal"

module DfeRb
  module Nfe
    # Rates fixed by law rather than chosen by the issuer.
    module Rates
      # Senate Resolution 22/1989: 7% from the South and Southeast (but Espírito Santo) to the
      # North, Northeast, Center-West and Espírito Santo; 12% otherwise.
      SOUTH_SOUTHEAST = %w[MG PR RJ RS SC SP].freeze
      # Senate Resolution 13/2012: 4% on imported goods (and domestic goods with more than 40%
      # imported content).
      IMPORTED_ORIGINS = %w[1 2 3 8].freeze

      # Share of the interstate ICMS that goes to the destination state (EC 87/2015, RV NA11-10).
      PARTITION = {2016 => 40, 2017 => 60, 2018 => 80}.freeze
      FULL_PARTITION_SINCE = 2019

      # IBS/CBS standard rates in percent per year (IT 2025.002 §05). A nil rate isn't law yet.
      IBS_CBS = {
        2026 => {uf: "0.10", municipal: "0", cbs: "0.90"},
        2027 => {uf: "0.05", municipal: "0.05", cbs: nil},
        2028 => {uf: "0.05", municipal: "0.05", cbs: nil}
      }.freeze

      # PIS and COFINS rates in percent: cumulative (Lei 9.718/1998, lucro presumido) and
      # non-cumulative (Leis 10.637/2002 and 10.833/2003, lucro real).
      PIS_COFINS = {
        cumulative: {pis: "0.65", cofins: "3.00"},
        non_cumulative: {pis: "1.65", cofins: "7.60"}
      }.freeze

      # Simples Nacional brackets (LC 123/2006 as amended by LC 155/2016), by gross revenue of
      # the last 12 months (RBT12). Each row is [ceiling, nominal rate in percent, amount to
      # deduct, ICMS share of the collection in percent]. Anexo I is commerce, Anexo II
      # industry. The last bracket is above the ICMS sublimit, so its ICMS is paid outside the
      # Simples and gives no credit.
      SIMPLES = {
        commerce: [
          [180_000, "4.00", 0, "34.00"], [360_000, "7.30", 5_940, "34.00"], [720_000, "9.50", 13_860, "33.50"],
          [1_800_000, "10.70", 22_500, "33.50"], [3_600_000, "14.30", 87_300, "33.50"], [4_800_000, "19.00", 378_000, nil]
        ],
        industry: [
          [180_000, "4.50", 0, "32.00"], [360_000, "7.80", 5_940, "32.00"], [720_000, "10.00", 13_860, "32.00"],
          [1_800_000, "11.20", 22_500, "32.00"], [3_600_000, "14.70", 85_500, "32.00"], [4_800_000, "30.00", 720_000, nil]
        ]
      }.freeze

      module_function

      # {pis:, cofins:} rates for a regime (:cumulative or :non_cumulative), as BigDecimals.
      def pis_cofins(regime)
        rates = PIS_COFINS[regime&.to_sym] or raise ArgumentError, "unknown PIS/COFINS regime #{regime.inspect} (use #{PIS_COFINS.keys.join(", ")})"
        rates.transform_values { |rate| BigDecimal(rate) }
      end

      # pCredSN: the ICMS credit rate (percent, 2 places) a Simples Nacional company passes on
      # with CSOSN 101, 201 or 900 (LC 123/2006, art. 23). It is the effective rate of the
      # company's bracket, (RBT12 x nominal rate - deduction) / RBT12, times the ICMS share.
      # `revenue_12m` is the RBT12 of the month before the operation; `annex` is :commerce
      # (Anexo I) or :industry (Anexo II). Returns nil without revenue or above the sublimit.
      # A state that reduces or exempts the ICMS of the Simples changes the credit. That is
      # state law, and yours to apply.
      def simples_icms_credit(revenue_12m:, annex: :commerce)
        brackets = SIMPLES[annex&.to_sym] or raise ArgumentError, "unknown annex #{annex.inspect} (use #{SIMPLES.keys.join(", ")})"
        revenue = BigDecimal(revenue_12m.to_s)
        return unless revenue.positive?

        _, nominal, deduction, share = brackets.find { |ceiling, *| revenue <= ceiling }
        return unless share

        effective = (revenue * BigDecimal(nominal) / 100 - deduction) / revenue * 100
        (effective * BigDecimal(share) / 100).round(2, half: :up)
      end

      # Interstate ICMS rate (percent) from `from` to `to` for goods of origin `origin`, or nil
      # for an operation within one state or abroad.
      def interstate(from, to, origin)
        return if from.nil? || to.nil? || from == to || [from, to].include?("EX")
        return BigDecimal(4) if IMPORTED_ORIGINS.include?(origin.to_s)

        (SOUTH_SOUTHEAST.include?(from) && !SOUTH_SOUTHEAST.include?(to)) ? BigDecimal(7) : BigDecimal(12)
      end

      # pICMSInterPart for an issue year, or nil before EC 87/2015.
      def partition(year)
        return BigDecimal(100) if year >= FULL_PARTITION_SINCE

        PARTITION[year] && BigDecimal(PARTITION[year])
      end

      # {uf:, municipal:, cbs:} standard rates for an issue year (each a BigDecimal or nil).
      def ibs_cbs(year)
        (IBS_CBS[year] || {}).transform_values { |rate| rate && BigDecimal(rate) }
      end

      # The ST margin (MVA, percent) adjusted when the interstate ICMS rate is below the
      # destination's internal one (Conv. ICMS 142/2018, cl. 11):
      # [(1 + MVA) x (1 - interstate) / (1 - internal)] - 1, to 2 places. Otherwise the
      # original MVA stands. The MVA and the internal rate are state law, so you give both.
      def adjusted_mva(mva, interstate:, internal:)
        mva, internal = [mva, internal].map { |value| BigDecimal(value.to_s) }
        return mva if interstate.nil?

        interstate = BigDecimal(interstate.to_s)
        return mva if interstate >= internal

        (((1 + mva / 100) * (1 - interstate / 100) / (1 - internal / 100) - 1) * 100).round(2, half: :up)
      end
    end
  end
end
