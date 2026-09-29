require "nokogiri"

module DfeRb
  module Nfe
    # An <NFe> handed in as XML (from another system, or a stored signed note), read with its
    # namespaces rather than by pattern, so quoting and formatting don't matter.
    class Document
      DECLARATION = /\A﻿?\s*<\?xml[^>]*\?>\s*/

      # The <NFe> element alone, ready to be placed inside enviNFe or nfeProc: no XML
      # declaration and, when the input is UTF-8, byte for byte what was given (a signature
      # covers the canonical form, so a re-encoded element still verifies).
      attr_reader :xml

      def initialize(xml)
        source = xml.to_s
        source = source.dup.force_encoding(Encoding::UTF_8) if source.encoding == Encoding::BINARY
        document = Nokogiri::XML(source) { |config| config.strict.nonet }
        @root = document.root
        unless @root&.name == "NFe" && @root.namespace&.href == Signature::NFE
          raise ValidationError, ["expected an <NFe> element in the #{Signature::NFE} namespace, got <#{@root&.name}>"]
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

      # The access key in infNFe/@Id, or nil.
      def key = info&.[]("Id")&.then { |id| id[/\ANFe([0-9A-Z]{44})\z/, 1] }

      # "1" (production) or "2" (homologação), as declared in ide/tpAmb.
      def environment = text("nfe:ide/nfe:tpAmb")

      def issuer_cnpj = text("nfe:emit/nfe:CNPJ")

      def issuer_cpf = text("nfe:emit/nfe:CPF")

      def signed? = !@root.at_xpath("ds:Signature", Signature::NAMESPACES).nil?

      # infNFe as the tag-keyed Hash the Validator reads, following the schema: repeatable
      # elements become Arrays, attributes "@name" keys, values text.
      def to_infnfe
        info ? read(info, Schema.nfe.find("infNFe")) : {}
      end

      private

      def info = @root.at_xpath("nfe:infNFe", Signature::NAMESPACES)

      def text(path) = info&.at_xpath(path, Signature::NAMESPACES)&.text&.strip

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
end
