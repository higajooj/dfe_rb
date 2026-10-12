module DfeRb
  module Nfe
    # The NF-e 4.00 layout (DfeRb::Schema), read from the official XSD.
    class Schema < DfeRb::Schema
      DIRECTORY = File.expand_path("../xml/schemas/nfe_4.00", __dir__)
      FILES = %w[leiauteNFe_v4.00.xsd tiposBasico_v4.00.xsd DFeTiposBasicos_v1.00.xsd].freeze

      # The <NFe> element.
      def self.nfe = (@nfe ||= new.root)

      def initialize(directory: DIRECTORY, files: FILES, type: "TNFe", tag: "NFe") = super
    end
  end
end
