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
      # The CBS of 2027 and 2028 comes from CBS_REFERENCE.
      IBS_CBS = {
        2026 => {uf: "0.10", municipal: "0", cbs: "0.90"},
        2027 => {uf: "0.05", municipal: "0.05", cbs: nil},
        2028 => {uf: "0.05", municipal: "0.05", cbs: nil}
      }.freeze
      # The CBS reference rate (alíquota de referência) in percent, by year: the Senate's
      # resolution, due by 31 October of the year before, or, while none is fixed past 22
      # December, the rate the TCU calculated (LC 214/2025, art. 349, §§ 1º and 2º). nil until
      # one of them applies. For 2027 the Senate has until 15/12/2026 (art. 353, § 2º, 45 more
      # days), and the TCU calculated 11.3% (TC 006.529/2026-7, 28/10/2026).
      CBS_REFERENCE = {2027 => nil, 2028 => nil}.freeze
      # In 2027 and 2028 the CBS is charged at its reference rate less 0.1 point, the IBS's
      # 0.05% + 0.05% (LC 214/2025, art. 347; EC 132/2023, ADCT art. 127). A reduced rate takes
      # the point off in proportion (§ 1º, I), as gRed does with the rate it reduces.
      CBS_TRANSITION_DISCOUNT = {2027 => "0.10", 2028 => "0.10"}.freeze
      # The year the CBS is charged in earnest: PIS/Pasep and COFINS end (EC 132/2023, ADCT art.
      # 126, II; LC 214/2025, art. 542) and the IPI's rates go to zero but on products with
      # incentivized industrialization in the Zona Franca de Manaus (ADCT art. 126, III, a; LC
      # 214/2025, art. 454).
      CBS_CHARGED_SINCE = 2027

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
        rates = (IBS_CBS[year] || {}).transform_values { |rate| rate && BigDecimal(rate) }
        reference = CBS_REFERENCE[year]
        rates[:cbs] ||= BigDecimal(reference) - BigDecimal(CBS_TRANSITION_DISCOUNT.fetch(year, "0")) if reference
        rates
      end

      # Whether PIS/Pasep and COFINS are charged on a note issued in `year` (an Integer, or
      # anything with #year): until 2026.
      def pis_cofins_charged?(year) = year_of(year) < CBS_CHARGED_SINCE

      # Whether the IPI is charged on a note issued in `year` (an Integer, or anything with
      # #year): until 2026 on every product, and from 2027 only on a product whose IPI the law
      # keeps (`zfm_product: true`): one with incentivized industrialization in the Zona Franca
      # de Manaus, unless LC 214/2025, art. 454 zeroes it too (a TIPI rate below 6.5% on
      # 31/12/2023, but not an ICT good). The Union is to list the products (§ 3º); until then
      # only the issuer knows.
      def ipi_applies?(year, zfm_product: false) = year_of(year) < CBS_CHARGED_SINCE || zfm_product == true

      # An Integer is the year itself, even where ActiveSupport gives it #year (a Duration of so
      # many years, which would compare as later than any year).
      def year_of(value)
        return value if value.is_a?(Integer)

        value.respond_to?(:year) ? value.year : Integer(value)
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
