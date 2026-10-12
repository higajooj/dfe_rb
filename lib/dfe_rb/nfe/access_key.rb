module DfeRb
  module Nfe
    # The chave de acesso of an NF-e: DfeRb::AccessKey, of modelo 55 unless told otherwise.
    class AccessKey < DfeRb::AccessKey
      def self.build(model: 55, **parts) = super

      # The infNFe/@Id attribute.
      def id = "NFe#{value}"
    end
  end
end
