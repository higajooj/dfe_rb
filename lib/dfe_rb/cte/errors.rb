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

    class Conflict < Error; end
  end
end
