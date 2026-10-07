require "securerandom"

module DfeRb
  module Nfe
    # The 44-character chave de acesso: cUF(2) AAMM(4) CNPJ(14) mod(2) serie(3) nNF(9)
    # tpEmis(1) cNF(8) cDV(1). CNPJ characters may be alphanumeric.
    class AccessKey
      FORMAT = /\A[0-9]{6}[0-9A-Z]{12}[0-9]{26}\z/

      # cNF values SEFAZ rejects (RV B03-10, rej. 897).
      FORBIDDEN_NUMERIC_CODES = (
        %w[00000000 12345678 23456789 34567890 45678901 56789012 67890123 78901234 89012345 90123456 01234567] +
        (1..9).map { |d| d.to_s * 8 }
      ).freeze

      attr_reader :value

      class << self
        # Builds the key. tax_id is a CNPJ (numeric or alphanumeric) or a CPF, which is
        # left-padded with zeros to 14 positions.
        def build(state:, issued_at:, tax_id:, series:, number:, numeric_code:, model: 55, emission_type: 1)
          id = TaxId.normalize(tax_id).rjust(14, "0")
          body = "#{States.code(state)}#{issued_at.strftime("%y%m")}#{id}#{format("%02d", model)}" \
            "#{format("%03d", series)}#{format("%09d", number)}#{emission_type}#{numeric_code.to_s.rjust(8, "0")}"
          new(body + check_digit(body))
        end

        def parse(value) = new(value)

        def valid?(value)
          key = value.to_s
          key.match?(FORMAT) && key[43] == check_digit(key[0, 43])
        end

        # Modulo 11 over the first 43 characters, weights 2..9 from the right.
        def check_digit(first43)
          weights = (2..9).cycle
          sum = first43.reverse.each_char.sum { |c| (c.ord - 48) * weights.next }
          rest = sum % 11
          ((rest < 2) ? 0 : 11 - rest).to_s
        end

        # A random cNF that SEFAZ accepts for this nNF: not a repeated/sequential pattern and
        # different from the invoice number.
        def generate_numeric_code(number:, random: SecureRandom)
          loop do
            code = format("%08d", random.random_number(100_000_000))
            return code unless FORBIDDEN_NUMERIC_CODES.include?(code) || code.to_i == number.to_i
          end
        end
      end

      def initialize(value)
        @value = value.to_s.upcase
        raise ArgumentError, "invalid access key: #{value.inspect}" unless self.class.valid?(@value)
      end

      def state_code = value[0, 2]

      def state = States::CODES.key(state_code.to_i)

      # Emission year and month, as the key's AAMM digits.
      def year_month = value[2, 4]

      def tax_id = value[6, 14]

      def model = value[20, 2].to_i

      def series = value[22, 3].to_i

      def number = value[25, 9].to_i

      def emission_type = value[34].to_i

      def numeric_code = value[35, 8]

      def check_digit = value[43]

      # The infNFe/@Id attribute.
      def id = "NFe#{value}"

      def to_s = value

      def ==(other) = value == (other.is_a?(AccessKey) ? other.value : other.to_s)

      alias_method :eql?, :==

      def hash = value.hash
    end
  end
end
