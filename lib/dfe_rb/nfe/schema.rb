require "nokogiri"

module DfeRb
  module Nfe
    # The NF-e 4.00 layout, read from the official XSD: element order, cardinality, choices
    # and value types. The builder, XML writer and docs all derive from this tree, so the gem
    # cannot drift from the schema SEFAZ validates against.
    class Schema
      XS = "http://www.w3.org/2001/XMLSchema"
      DIRECTORY = File.expand_path("../xml/schemas/nfe_4.00", __dir__)
      FILES = %w[leiauteNFe_v4.00.xsd tiposBasico_v4.00.xsd DFeTiposBasicos_v1.00.xsd].freeze

      # A named or inline value type with the facets the writer and validator care about.
      SimpleType = Data.define(:name, :root, :patterns, :enumeration, :min_length, :max_length, :length) do
        # Built-in XSD type at the bottom of the derivation chain ("string", "date", ...).
        def string? = %w[string token normalizedString].include?(root)

        def base64? = root == "base64Binary"

        def date? = root == "date"

        def date_time? = root == "dateTime"

        def year_month? = root == "gYearMonth"

        def enumerated? = !enumeration.empty?
      end

      # An element, or a `choice`/`sequence` group of elements. `children` are Elements and
      # Groups, in schema order.
      Element = Data.define(:tag, :min, :max, :type, :children, :attributes, :doc, :path) do
        def leaf? = children.empty?

        def optional? = min.zero?

        def repeatable? = max > 1

        def find(tag) = each_element.find { |element| element.tag == tag.to_s }

        # Elements directly under this one, with sequence/choice groups flattened.
        def each_element(&block)
          return enum_for(:each_element) unless block

          children.each do |child|
            child.is_a?(Group) ? child.each_element(&block) : yield(child)
          end
        end

        def inspect = "#<Element #{path}>"
      end

      Group = Data.define(:kind, :min, :max, :children) do
        def choice? = kind == :choice

        def each_element(&block)
          return enum_for(:each_element) unless block

          children.each do |child|
            child.is_a?(Group) ? child.each_element(&block) : yield(child)
          end
        end
      end

      Attribute = Data.define(:name, :type, :required, :fixed)

      class << self
        # The <NFe> element.
        def nfe = (@nfe ||= new.root)
      end

      attr_reader :root

      def initialize
        @documents = FILES.map { |file| Nokogiri::XML(File.read(File.join(DIRECTORY, file))) }
        @complex_types = index("complexType")
        @simple_types = index("simpleType")
        @root = build_nfe
      end

      private

      def index(kind)
        @documents.each_with_object({}) do |document, types|
          document.xpath("/xs:schema/xs:#{kind}[@name]", "xs" => XS).each { |node| types[node["name"]] = node }
        end
      end

      def build_nfe
        complex = @complex_types.fetch("TNFe")
        Element.new(tag: "NFe", min: 1, max: 1, type: nil, children: parse_complex(complex, "NFe"),
          attributes: [], doc: nil, path: "NFe")
      end

      def parse_complex(complex, path)
        particle = complex.element_children.find { |child| %w[sequence choice].include?(child.name) }
        return [] unless particle

        children = parse_particle(particle, path)
        return children unless particle.name == "choice"

        [Group.new(kind: :choice, min: occurs(particle, "minOccurs"), max: occurs(particle, "maxOccurs"), children: children)]
      end

      def parse_particle(node, path)
        node.element_children.filter_map do |child|
          case child.name
          when "element" then parse_element(child, path)
          when "sequence", "choice"
            Group.new(kind: child.name.to_sym, min: occurs(child, "minOccurs"), max: occurs(child, "maxOccurs"),
              children: parse_particle(child, path))
          end
        end
      end

      def parse_element(node, parent_path)
        if node["ref"]
          tag = node["ref"].split(":").last
          return Element.new(tag: tag, min: occurs(node, "minOccurs"), max: occurs(node, "maxOccurs"), type: nil,
            children: [], attributes: [], doc: nil, path: "#{parent_path}/#{tag}")
        end

        tag = node["name"]
        path = "#{parent_path}/#{tag}"
        type = nil
        children = []
        attributes = []

        if node["type"]
          type_name = node["type"].split(":").last
          if @complex_types.key?(type_name)
            children = parse_complex(@complex_types[type_name], path)
            attributes = parse_attributes(@complex_types[type_name])
          else
            type = simple_type(type_name)
          end
        elsif (inline = node.at_xpath("xs:simpleType", "xs" => XS))
          type = parse_simple(inline, nil)
        elsif (inline = node.at_xpath("xs:complexType", "xs" => XS))
          children = parse_complex(inline, path)
          attributes = parse_attributes(inline)
        end

        Element.new(tag: tag, min: occurs(node, "minOccurs"), max: occurs(node, "maxOccurs"), type: type,
          children: children, attributes: attributes, doc: documentation(node), path: path)
      end

      def parse_attributes(complex)
        complex.xpath("xs:attribute", "xs" => XS).map do |attribute|
          Attribute.new(name: attribute["name"], type: attribute["type"] && simple_type(attribute["type"].split(":").last),
            required: attribute["use"] == "required", fixed: attribute["fixed"])
        end
      end

      def simple_type(name)
        @simple_cache ||= {}
        @simple_cache[name] ||= if @simple_types.key?(name)
          parse_simple(@simple_types[name], name)
        else
          SimpleType.new(name: name, root: name, patterns: [], enumeration: [], min_length: nil, max_length: nil, length: nil)
        end
      end

      def parse_simple(node, name)
        restriction = node.at_xpath("xs:restriction", "xs" => XS)
        return SimpleType.new(name: name, root: "string", patterns: [], enumeration: [], min_length: nil, max_length: nil, length: nil) unless restriction

        base_name = restriction["base"].split(":").last
        base = simple_type(base_name)
        facets = ->(facet) { restriction.xpath("xs:#{facet}", "xs" => XS).map { |f| f["value"] } }

        SimpleType.new(
          name: name || base.name,
          root: base.root,
          patterns: facets.call("pattern").then { |own| own.empty? ? base.patterns : own },
          enumeration: facets.call("enumeration").then { |own| own.empty? ? base.enumeration : own },
          min_length: facets.call("minLength").first&.to_i || base.min_length,
          max_length: facets.call("maxLength").first&.to_i || base.max_length,
          length: facets.call("length").first&.to_i || base.length
        )
      end

      def occurs(node, attribute)
        value = node[attribute]
        return 1 if value.nil?

        (value == "unbounded") ? Float::INFINITY : value.to_i
      end

      def documentation(node)
        node.at_xpath("xs:annotation/xs:documentation", "xs" => XS)&.text&.strip
      end
    end
  end
end
