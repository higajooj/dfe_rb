module DfeRb
  module Nfe
    module Distribution
      # Strict, namespace-aware readers shared by responses, documents and restored events
      # (DfeRb::Distribution::Reader, in the NF-e namespace).
      module Xml
        NS = Signature::NAMESPACES
        READER = DfeRb::Distribution::Reader.new(namespace: Signature::NFE, label: "NF-e")

        module_function

        def parse(source, root: nil) = READER.parse(source, root: root)

        def element(node, path, required: false) = READER.element(node, path, required: required)

        def text(node, path, required: false) = READER.text(node, path, required: required)

        def integer(node, path, required: false) = READER.integer(node, path, required: required)

        def time(node, path, required: false) = READER.time(node, path, required: required)

        def fragment(node) = READER.fragment(node)

        def nsu(value, allow_zero: true) = READER.nsu(value, allow_zero: allow_zero)

        def key(value)
          parsed = AccessKey.parse(value.to_s)
          raise ArgumentError, "expected an NF-e access key (model 55)" unless parsed.model == 55
          parsed.to_s.freeze
        end

        def freeze_values(values) = READER.freeze_values(values)
      end
    end
  end
end
