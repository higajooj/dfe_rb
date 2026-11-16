module DfeRb
  module Nfe
    # How an issuer's regime says its IBS/CBS go on the note (NT 2026.005 v1.00, §2.3): which of
    # tpRegimeIBSCBS and cAtivSN it gives, whether the item's gIBSCBS and its gTribSN (the
    # Simples Nacional's own IBS and CBS, gIBSSN and gCBSSN) are informed, and the one case where
    # the CBS of gIBSCBS is zero.
    #
    #   CRT  tpRegimeIBSCBS  gIBSCBS            gTribSN
    #   1    1  (regular)    UF, Mun, CBS       none
    #   2    1  (regular)    UF, Mun, CBS       none
    #   1    none            none               gIBSSN, gCBSSN
    #   2    none            UF, Mun, CBS = 0   gCBSSN
    #   3    2               UF, Mun, CBS       gIBSSN, gCBSSN
    #   3    3               UF, Mun, CBS       gCBSSN
    #   3    4               UF, Mun, CBS       none
    #   4 (MEI)              no IBSCBS at all
    #
    # A regime normal issuer (CRT 3 without tpRegimeIBSCBS) is not in the table: nothing here
    # constrains it but cAtivSN, which only an optante or one with the option pending gives.
    module SimplesIbsCbs
      NORMAL = "3"
      MEI = "4"
      # When the NT's rules apply, by tpAmb: homologação by 26/10/2026; production moved from
      # 16/11 to 14/12/2026 by the Portal's aviso of 13/11/2026.
      RULES_SINCE = {"2" => Time.new(2026, 10, 26, 0, 0, 0, "-03:00"), "1" => Time.new(2026, 12, 14, 0, 0, 0, "-03:00")}.freeze
      SIMPLES = %w[1 2].freeze
      # tpRegimeIBSCBS 1 is the optante's choice of the regular regime; 2, 3 and 4 are the
      # regime normal issuer whose option for the Simples Nacional is pending.
      REGULAR = "1"
      PENDING = %w[2 3 4].freeze

      # activity: the issuer gives cAtivSN. main: the item's gIBSCBS (false: not informed, nil:
      # up to the CST). ibs_sn, cbs_sn: which of gTribSN's groups it carries; nil: not
      # constrained. zero_cbs: gIBSCBS/gCBS at rate zero. problem: why the pair isn't one the NT
      # names (tpRegimeIBSCBS "must not be informed for other situations").
      Layout = Data.define(:activity, :main, :ibs_sn, :cbs_sn, :zero_cbs, :mei, :problem) do
        def initialize(activity: false, main: nil, ibs_sn: nil, cbs_sn: nil, zero_cbs: false, mei: false, problem: nil)
          super
        end
      end

      module_function

      # The layout for an issuer (its resolved <emit>), or nil when the issuer has no CRT.
      def layout(emit)
        crt = emit&.[]("CRT").to_s
        regime = emit&.[]("tpRegimeIBSCBS").to_s
        return if crt.empty?
        return Layout.new(mei: true, problem: (regime.empty? ? nil : not_for_mei)) if crt == MEI

        if SIMPLES.include?(crt)
          return Layout.new(problem: unexpected(crt, regime)) unless regime.empty? || regime == REGULAR
          return Layout.new(activity: true, ibs_sn: false, cbs_sn: false) if regime == REGULAR

          (crt == "1") ? Layout.new(activity: true, main: false, ibs_sn: true, cbs_sn: true) : Layout.new(activity: true, ibs_sn: false, cbs_sn: true, zero_cbs: true)
        else
          return Layout.new(problem: unexpected(crt, regime)) if regime == REGULAR
          return Layout.new if regime.empty?

          Layout.new(activity: true, ibs_sn: regime == "2", cbs_sn: regime != "4")
        end
      end

      # Whether the NT applies to a note of environment `tp_amb` issued at `time`.
      def in_force?(tp_amb, time)
        since = RULES_SINCE[tp_amb.to_s]
        !!(since && time && time >= since)
      end

      def unexpected(crt, regime)
        "tpRegimeIBSCBS #{regime} is not one of CRT #{crt} (1 for a Simples Nacional issuer that chose the regular regime of the IBS " \
          "and the CBS, 2, 3 or 4 for a regime normal one with its option for the Simples Nacional pending; NT 2026.005 §2.1)"
      end

      def not_for_mei = "a MEI (CRT 4) has no tpRegimeIBSCBS (NT 2026.005 §2.1)"
    end
  end
end
