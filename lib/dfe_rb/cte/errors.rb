module DfeRb
  module Cte
    class Error < DfeRb::Error; end

    class Rejected < Error
      attr_reader :result

      def initialize(result)
        @result = result
        super("#{result.code} #{result.message}")
      end
    end

    class ConsumptionBlocked < Rejected; end

    class Conflict < Error
      attr_reader :existing_key

      def initialize(message = nil, existing_key: nil)
        @existing_key = existing_key&.dup&.freeze
        super(message)
      end
    end

    class InvalidResponse < TransportError
      attr_reader :response_xml

      def initialize(message, response_xml: nil, maybe_processed: true)
        @response_xml = response_xml&.to_s&.dup&.freeze
        super(message, maybe_processed: maybe_processed)
      end
    end
  end
end
