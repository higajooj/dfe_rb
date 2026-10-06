module DfeRb
  module Nfe
    # IBGE state codes and the SEFAZ that authorizes each state's NF-e: the state's own
    # (:own), the SEFAZ Virtual do Ambiente Nacional (:svan) or the SEFAZ Virtual RS (:svrs).
    module States
      CODES = {
        "AC" => 12, "AL" => 27, "AM" => 13, "AP" => 16, "BA" => 29, "CE" => 23, "DF" => 53,
        "ES" => 32, "GO" => 52, "MA" => 21, "MG" => 31, "MS" => 50, "MT" => 51, "PA" => 15,
        "PB" => 25, "PE" => 26, "PI" => 22, "PR" => 41, "RJ" => 33, "RN" => 24, "RO" => 11,
        "RR" => 14, "RS" => 43, "SC" => 42, "SE" => 28, "SP" => 35, "TO" => 17
      }.freeze

      # UTC offsets that differ from Brasília time (-03:00), all year round.
      UTC_OFFSETS = {"AC" => "-05:00", "AM" => "-04:00", "MT" => "-04:00", "MS" => "-04:00", "RO" => "-04:00", "RR" => "-04:00"}.freeze
      DEFAULT_UTC_OFFSET = "-03:00"

      OWN_AUTHORIZER = %w[AM BA GO MG MS MT PE PR RS SP].freeze
      SVAN = %w[MA].freeze
      # States whose contingency authorizer is the SVC-AN; the others use the SVC-RS (Portal
      # Nacional da NF-e, "Autorizadores em contingência", which updates Anexo III 2.1.3.1).
      SVC_AN = %w[AC AL AP CE DF ES MG PA PB PI RJ RN RO RR RS SC SE SP TO].freeze
      SVC_EMISSION_TYPES = {"SVC-AN" => 6, "SVC-RS" => 7}.freeze
      # States whose taxpayers can't register an EPEC (Ajuste SINIEF 25/2026, RV 2P10-20).
      EPEC_BARRED = %w[PR PB].freeze

      module_function

      def abbreviation(state)
        value = state.to_s.strip
        return value.upcase if CODES.key?(value.upcase)
        abbreviation = CODES.key(Integer(value, exception: false))
        abbreviation or raise ArgumentError, "unknown state: #{state.inspect}"
      end

      # The current time in the state's UTC offset, whole hours as the layout requires.
      def now(state, clock = Time)
        clock.now.getlocal(UTC_OFFSETS.fetch(abbreviation(state), DEFAULT_UTC_OFFSET))
      end

      # IBGE code as a 2-digit string.
      def code(state) = CODES.fetch(abbreviation(state)).to_s

      # Name of the SEFAZ that authorizes the state's NF-e: an own-authorizer state
      # abbreviation ("SP"), "SVAN" or "SVRS".
      def authorizer(state)
        uf = abbreviation(state)
        if OWN_AUTHORIZER.include?(uf)
          uf
        elsif SVAN.include?(uf)
          "SVAN"
        else
          "SVRS"
        end
      end

      # The SEFAZ Virtual de Contingência that authorizes the state's NF-e while its own
      # authorizer is down: "SVC-AN" or "SVC-RS".
      def contingency(state) = SVC_AN.include?(abbreviation(state)) ? "SVC-AN" : "SVC-RS"

      # tpEmis of a note sent to the state's SVC: 6 (SVC-AN) or 7 (SVC-RS).
      def contingency_emission_type(state) = SVC_EMISSION_TYPES.fetch(contingency(state))
    end
  end
end
