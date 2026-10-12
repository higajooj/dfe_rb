require "nokogiri"

module DfeRb
  # A document handed in as XML (from another system, or a stored signed one), read with its
  # namespaces rather than by pattern, so quoting and formatting don't matter. A subclass
  # says which document it is: ROOT ("NFe"), INFO ("infNFe"), NAMESPACE and ID_PREFIX.
  class Document
    KEY = /\A[0-9A-Z]{44}\z/
    DECLARATION = /\A﻿?\s*<\?xml[^>]*\?>\s*/

    # The root element alone, ready to be placed inside a request or a proc file: no XML
    # declaration and, when the input is UTF-8, byte for byte what was given (a signature
    # covers the canonical form, so a re-encoded element still verifies).
    attr_reader :xml

    def initialize(xml)
      source = xml.to_s
      source = source.dup.force_encoding(Encoding::UTF_8) if source.encoding == Encoding::BINARY
      document = Nokogiri::XML(source) { |config| config.strict.nonet }
      @root = document.root
      unless @root&.name == root_tag && @root.namespace&.href == namespace
        raise ValidationError, ["expected an <#{root_tag}> element in the #{namespace} namespace, got <#{@root&.name}>"]
      end

      utf8 = document.encoding.nil? || document.encoding.match?(/\Autf-?8\z/i)
      @xml = if utf8
        source.sub(DECLARATION, "").rstrip
      else
        @root.to_xml(encoding: "UTF-8", save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
      end
    rescue Nokogiri::XML::SyntaxError => e
      raise ValidationError, ["not well-formed XML: #{e.message}"]
    end

    # The access key in the info element's Id, or nil.
    def key
      id = info&.[]("Id").to_s
      prefix = self.class::ID_PREFIX
      id.delete_prefix(prefix) if id.start_with?(prefix) && id.length == prefix.length + 44 && id[prefix.length..].match?(KEY)
    end

    # "1" (production) or "2" (homologação), as declared in ide/tpAmb.
    def environment = text("ide/tpAmb")

    def issuer_cnpj = text("emit/CNPJ")

    def issuer_cpf = text("emit/CPF")

    def signed? = !@root.at_xpath("ds:Signature", namespaces).nil?

    # The info element as a tag-keyed Hash following `element` (its schema). Repeatable
    # elements become Arrays, attributes become "@name" keys and values are text.
    def tree(element)
      info ? read(info, element) : {}
    end

    private

    def root_tag = self.class::ROOT

    def namespace = self.class::NAMESPACE

    def namespaces = {"doc" => namespace, "ds" => Signature::DS}

    def info = @root.at_xpath("doc:#{self.class::INFO}", namespaces)

    # Text at a tag path under the info element ("emit/CNPJ").
    def text(path)
      info&.at_xpath(path.split("/").map { |tag| "doc:#{tag}" }.join("/"), namespaces)&.text&.strip
    end

    def read(node, element)
      data = node.attribute_nodes.to_h { |attribute| ["@#{attribute.name}", attribute.value] }
      children = node.element_children.group_by(&:name)
      element.each_element do |child|
        found = children[child.tag] or next

        values = found.map { |entry| child.leaf? ? entry.text : read(entry, child) }
        data[child.tag] = child.repeatable? ? values : values.first
      end
      data
    end
  end
end
