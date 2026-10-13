module DfeRb
  module Mdfe
    # The chave de acesso of an MDF-e: DfeRb::AccessKey, of modelo 58.
    class AccessKey < DfeRb::AccessKey
      MODEL = 58
      # Series kept for an issuer that is a person (F69, F70).
      PERSON_SERIES = (920..969)

      def self.build(model: MODEL, **parts) = super

      # The infMDFe/@Id attribute.
      def id = "MDFe#{value}"

      # Whether the issuer is a person, which the series tells: a CNPJ may start with zeros
      # just as a CPF padded to 14 positions does.
      def person? = PERSON_SERIES.cover?(series)

      # The issuer's CNPJ, or CPF.
      def issuer_id = person? ? tax_id[3..] : tax_id
    end
  end
end
