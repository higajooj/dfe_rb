module DfeRb
  # SEFAZ has two environments: production (tpAmb 1) and homologação (tpAmb 2). Notes issued
  # in homologação have no fiscal value.
  module Environment
    PRODUCTION = :production
    HOMOLOGACAO = :homologacao

    ALIASES = {
      :production => PRODUCTION, :producao => PRODUCTION, :prod => PRODUCTION, "1" => PRODUCTION, 1 => PRODUCTION,
      :homologacao => HOMOLOGACAO, :homologation => HOMOLOGACAO, :hom => HOMOLOGACAO, :test => HOMOLOGACAO,
      :staging => HOMOLOGACAO, "2" => HOMOLOGACAO, 2 => HOMOLOGACAO
    }.freeze

    module_function

    # :production or :homologacao, from a symbol/string alias or the tpAmb code.
    def normalize(value)
      key = value.is_a?(Integer) ? value : value.to_s.downcase.to_sym
      ALIASES[key] || ALIASES[value.to_s] or raise ArgumentError, "unknown environment: #{value.inspect} (use :production or :homologacao)"
    end

    # The tpAmb value: "1" or "2".
    def code(environment) = (normalize(environment) == PRODUCTION) ? "1" : "2"
  end
end
