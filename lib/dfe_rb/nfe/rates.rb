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

      module_function

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

      # The ST margin (MVA, percent) adjusted for an interstate ICMS rate below the
      # destination's internal one (Conv. ICMS 142/2018, cl. 11):
      # [(1 + MVA) x (1 - interstate) / (1 - internal)] - 1, 2 places. The original MVA holds
      # otherwise. The MVA and the internal rate are state law, so both are given.
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
