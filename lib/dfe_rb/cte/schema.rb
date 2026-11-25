module DfeRb
  module Cte
    module Schema
      DIRECTORY = File.expand_path("../xml/schemas/cte_4.00", __dir__)
      FILES = %w[cteTiposBasico_v4.00.xsd tiposGeralCTe_v4.00.xsd DFeTiposBasicos_v1.00.xsd].freeze
      VERSION = "4.00"
      MODALS = {
        "rodo" => ["cteModalRodoviario_v4.00.xsd", "01"],
        "aereo" => ["cteModalAereo_v4.00.xsd", "02"],
        "aquav" => ["cteModalAquaviario_v4.00.xsd", "03"],
        "ferrov" => ["cteModalFerroviario_v4.00.xsd", "04"],
        "duto" => ["cteModalDutoviario_v4.00.xsd", "05"],
        "multimodal" => ["cteMultiModal_v4.00.xsd", "06"]
      }.freeze

      class << self
        def cte = (@cte ||= build)

        private

        def build
          root = DfeRb::Schema.new(directory: DIRECTORY, files: FILES, type: "TCTe", tag: "CTe").root
          modals = MODALS.map do |tag, (file, _code)|
            DfeRb::Schema.new(directory: DIRECTORY, files: [file, *FILES], element: tag, path: "CTe/infCte/infCTeNorm/infModal").root
          end
          graft(root, %w[infCte infCTeNorm infModal], [DfeRb::Schema::Group.new(kind: :choice, min: 1, max: 1, children: modals)])
        end

        def graft(element, tags, children)
          return element.with(children: children) if tags.empty?

          element.with(children: element.children.map do |child|
            if child.is_a?(DfeRb::Schema::Group)
              graft(child, tags, children)
            elsif child.is_a?(DfeRb::Schema::Element) && child.tag == tags.first
              graft(child, tags.drop(1), children)
            else
              child
            end
          end)
        end
      end
    end
  end
end
