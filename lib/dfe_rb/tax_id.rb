module DfeRb
  # Normalizes CNPJ (numeric or alphanumeric, IN RFB 2229/24) and CPF values and validates
  # their check digits. Alphanumeric characters count as their ASCII code minus 48 (A = 17
  # ... Z = 42), which is also how digits count, so one algorithm covers both kinds of CNPJ.
  module TaxId
    CNPJ_FORMAT = /\A[0-9A-Z]{12}[0-9]{2}\z/
    CPF_FORMAT = /\A[0-9]{11}\z/

    module_function

    # "12.ABC.345/01DE-35" => "12ABC34501DE35"
    def normalize(value)
      value.to_s.upcase.gsub(/[.\-\/\s]/, "")
    end

    def cnpj?(value) = valid_cnpj?(normalize(value))

    def cpf?(value) = valid_cpf?(normalize(value))

    # :cnpj, :cpf, or nil when the value is neither (or has a wrong check digit).
    def type(value)
      id = normalize(value)
      if valid_cnpj?(id)
        :cnpj
      elsif valid_cpf?(id)
        :cpf
      end
    end

    def valid_cnpj?(id)
      id.match?(CNPJ_FORMAT) && id[0, 12].squeeze.length > 1 && id[12, 2] == cnpj_check_digits(id[0, 12])
    end

    def valid_cpf?(id)
      id.match?(CPF_FORMAT) && id.squeeze.length > 1 && id[9, 2] == cpf_check_digits(id[0, 9])
    end

    # The two check digits for a 12-character CNPJ root (8 root + 4 branch).
    def cnpj_check_digits(base)
      digits = +""
      2.times do
        weights = (2..9).cycle
        sum = (base + digits).reverse.each_char.sum { |c| (c.ord - 48) * weights.next }
        rest = sum % 11
        digits << ((rest < 2) ? 0 : 11 - rest).to_s
      end
      digits
    end

    def cpf_check_digits(base)
      digits = +""
      2.times do
        numbers = (base + digits).each_char.map(&:to_i)
        sum = numbers.each_with_index.sum { |n, i| n * (numbers.size + 1 - i) }
        rest = (sum * 10) % 11
        digits << ((rest == 10) ? 0 : rest).to_s
      end
      digits
    end
  end
end
