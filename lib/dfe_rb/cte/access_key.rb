module DfeRb
  module Cte
    class AccessKey < DfeRb::AccessKey
      MODEL = 57
      PERSON_SERIES = (920..969)

      def self.build(model: MODEL, **parts) = super

      def id = "CTe#{value}"

      def person? = PERSON_SERIES.cover?(series)

      def issuer_id = person? ? tax_id[3..] : tax_id
    end
  end
end
