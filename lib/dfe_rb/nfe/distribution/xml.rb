module DfeRb
  module Nfe
    module Distribution
      # Strict, namespace-aware readers shared by responses, documents and restored events.
      # They never expand entities or read DTDs, external resources or schema names from a
      # response.
      module Xml
        NS = Signature::NAMESPACES

        module_function

        def parse(source, root: nil)
          doc = Nokogiri::XML(source) { |config| config.strict.nonet }
          raise ArgumentError, "XML contains a DTD" if doc.internal_subset || doc.external_subset
          raise ArgumentError, "XML has no root" unless doc.root
          if root && (doc.root.name != root || doc.root.namespace&.href != Signature::NFE)
            raise ArgumentError, "expected <#{root}> in the NF-e namespace"
          end
          doc
        end

        def element(node, path, required: false)
          matches = node.xpath(path.split("/").map { |tag| "nfe:#{tag}" }.join("/"), NS)
          raise ArgumentError, "multiple #{path} elements" if matches.size > 1
          raise ArgumentError, "missing #{path}" if required && matches.empty?
          matches.first
        end

        def text(node, path, required: false)
          value = element(node, path, required: required)&.text&.strip
          raise ArgumentError, "missing #{path}" if required && (value.nil? || value.empty?)
          value&.freeze
        end

        def integer(node, path, required: false)
          value = text(node, path, required: required)
          return unless value
          raise ArgumentError, "invalid #{path}: #{value.inspect}" unless value.match?(/\A\d+\z/)
          value.to_i
        end

        def time(node, path, required: false)
          value = text(node, path, required: required)
          return unless value
          unless value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\z/)
            raise ArgumentError, "invalid #{path}: expected an ISO 8601 timestamp with UTC offset"
          end
          DateTime.iso8601(value) # validate the calendar date, not just Time's normalization
          Time.iso8601(value).freeze
        end

        def fragment(node)
          node.dup.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML).freeze
        end

        def nsu(value, allow_zero: true)
          supported_type = value.is_a?(Integer) || value.is_a?(String)
          unless supported_type && value.to_s.match?(/\A[0-9]{1,15}\z/)
            raise ArgumentError, "NSU must be an integer or a string of 1..15 digits"
          end
          raise ArgumentError, "NSU must be greater than zero" if !allow_zero && value.to_i.zero?
          value.to_s.rjust(15, "0").freeze
        end

        def key(value)
          parsed = AccessKey.parse(value.to_s)
          raise ArgumentError, "expected an NF-e access key (model 55)" unless parsed.model == 55
          parsed.to_s.freeze
        end

        def freeze_values(values)
          values.transform_values { |value| value.is_a?(String) ? value.dup.freeze : value.freeze }
        end
      end
    end
  end
end
