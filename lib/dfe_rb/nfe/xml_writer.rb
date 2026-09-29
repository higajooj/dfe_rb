module DfeRb
  module Nfe
    # Writes a tree of values as compact NF-e XML (no whitespace between tags, as SEFAZ
    # requires), following the schema's element order. The tree is nested Hashes keyed by XML
    # tag; repeatable elements hold Arrays; attributes are keys starting with "@".
    #
    # Problems with individual values (bad decimal, too long text...) are collected in #issues
    # instead of aborting, so a caller can report all of them at once.
    class XmlWriter
      NAMESPACE = "http://www.portalfiscal.inf.br/nfe"

      attr_reader :issues

      def initialize(schema = Schema.nfe)
        @schema = schema
        @issues = []
      end

      # The <NFe> element (no XML declaration, no signature).
      def write(tree)
        @issues.clear
        out = +""
        write_element(out, @schema, tree, "NFe", root: true)
        out
      end

      private

      def write_element(out, element, data, path, root: false)
        attributes = attributes_of(data)
        attributes = %( xmlns="#{NAMESPACE}") + attributes if root

        if element.leaf?
          text = leaf_text(element, data, path)
          return if text.nil? && element.type

          out << "<#{element.tag}#{attributes}>#{escape(text.to_s)}</#{element.tag}>"
        else
          fields = data.is_a?(Hash) ? data : {}
          report_unknown(element, fields, path)
          out << "<#{element.tag}#{attributes}>"
          write_children(out, element.children, fields, path)
          out << "</#{element.tag}>"
        end
      end

      def report_unknown(element, fields, path)
        known = element.each_element.map(&:tag)
        fields.each_key do |key|
          next if key.to_s.start_with?("@") || known.include?(key.to_s)

          @issues << "#{path}: unknown element #{key}"
        end
      end

      def write_children(out, children, data, path)
        children.each do |child|
          case child
          when Schema::Element then write_occurrences(out, child, data, path)
          when Schema::Group then write_group(out, child, data, path)
          end
        end
      end

      def write_group(out, group, data, path)
        return write_children(out, group.children, data, path) unless group.choice?

        given = tags_of(group).select { |tag| !data[tag].nil? }
        return if given.empty?

        # The alternative that accounts for everything given: ICMS + IPI belongs to the
        # goods branch of <imposto>, ISSQN + IPI to the services branch.
        covering = group.children.select { |alternative| (given - tags_of(alternative)).empty? }
        if covering.empty?
          @issues << "#{path}: #{given.join(" and ")} cannot be given together (choose one of #{group.children.map { |c| tags_of(c).first }.join("/")})"
        else
          write_children(out, [covering.first], data, path)
        end
      end

      def write_occurrences(out, element, data, path)
        values = data[element.tag]
        return if values.nil?

        values = [values] unless values.is_a?(Array) && element.repeatable?
        if values.size > element.max
          @issues << "#{path}/#{element.tag}: at most #{element.max} allowed, got #{values.size}"
        end

        values.each_with_index do |value, index|
          suffix = element.repeatable? ? "#{element.tag}[#{index + 1}]" : element.tag
          write_element(out, element, value, "#{path}/#{suffix}")
        end
      end

      def leaf_text(element, value, path)
        return "" if value.nil? || !element.type

        Formatter.format(value, element)
      rescue Formatter::Invalid => e
        @issues << "#{path}: #{e.message}"
        nil
      end

      def attributes_of(data)
        return "" unless data.is_a?(Hash)

        data.filter_map do |key, value|
          next unless key.to_s.start_with?("@") && !value.nil?

          %( #{key.to_s.delete_prefix("@")}="#{escape(value.to_s, attribute: true)}")
        end.join
      end

      # Tags of the elements a node (element or group) contributes to its parent.
      def tags_of(node)
        case node
        when Schema::Element then [node.tag]
        when Schema::Group then node.children.flat_map { |child| tags_of(child) }
        end
      end

      def escape(text, attribute: false)
        escaped = text.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
        attribute ? escaped.gsub('"', "&quot;") : escaped
      end
    end
  end
end
