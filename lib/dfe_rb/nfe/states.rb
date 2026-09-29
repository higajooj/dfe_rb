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
    end
  end
end
