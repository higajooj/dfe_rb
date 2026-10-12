module DfeRb
  module Mdfe
    # The MDF-e 3.00 layout (DfeRb::Schema), read from the official XSD. The layout leaves
    # infModal open (xs:any) and describes each modal in a schema of its own; here the four
    # of them are placed under infModal as a choice, so the builder and the writer see one tree.
    module Schema
      DIRECTORY = File.expand_path("../xml/schemas/mdfe_3.00", __dir__)
      FILES = %w[mdfeTiposBasico_v3.00.xsd tiposGeralMDFe_v3.00.xsd].freeze
      VERSION = "3.00"
      # Modal element => [its schema, the ide/modal code].
      MODALS = {
        "rodo" => ["mdfeModalRodoviario_v3.00.xsd", 1],
        "aereo" => ["mdfeModalAereo_v3.00.xsd", 2],
        "aquav" => ["mdfeModalAquaviario_v3.00.xsd", 3],
        "ferrov" => ["mdfeModalFerroviario_v3.00.xsd", 4]
      }.freeze

      class << self
        # The <MDFe> element.
        def mdfe = (@mdfe ||= build)

        private

        def build
          root = DfeRb::Schema.new(directory: DIRECTORY, files: FILES, type: "TMDFe", tag: "MDFe").root
          modals = MODALS.map do |tag, (file, _code)|
            DfeRb::Schema.new(directory: DIRECTORY, files: [file, *FILES], element: tag, path: "MDFe/infMDFe/infModal").root
          end
          graft(root, %w[infMDFe infModal], [DfeRb::Schema::Group.new(kind: :choice, min: 1, max: 1, children: modals)])
        end

        # A copy of `element` whose descendant at `tags` has `children`.
        def graft(element, tags, children)
          return element.with(children: children) if tags.empty?

          element.with(children: element.children.map do |child|
            (child.is_a?(DfeRb::Schema::Element) && child.tag == tags.first) ? graft(child, tags.drop(1), children) : child
          end)
        end
      end
    end
  end
end
