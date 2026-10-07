module DfeRb
  module Nfe
    module Distribution
      # An unusable answer, not an ordinary SEFAZ rejection. It keeps the raw response, so a
      # consumer can diagnose corruption without discarding it or advancing its cursor.
      class InvalidResponse < TransportError
        attr_reader :response_xml, :schema, :nsu

        def initialize(message, response_xml:, schema: nil, nsu: nil)
          @response_xml = response_xml.to_s.dup.freeze
          @schema = schema&.dup&.freeze
          @nsu = nsu&.dup&.freeze
          super(message, maybe_processed: true)
        end
      end
    end
  end
end
