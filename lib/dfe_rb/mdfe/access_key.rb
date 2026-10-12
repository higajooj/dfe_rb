module DfeRb
  module Mdfe
    # The chave de acesso of an MDF-e: DfeRb::AccessKey, of modelo 58.
    class AccessKey < DfeRb::AccessKey
      MODEL = 58

      def self.build(model: MODEL, **parts) = super

      # The infMDFe/@Id attribute.
      def id = "MDFe#{value}"
    end
  end
end
