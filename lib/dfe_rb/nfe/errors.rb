module DfeRb
  module Nfe
    class Error < DfeRb::Error; end

    # Raised by the bang methods (authorize!...) when SEFAZ rejected the request. #result has
    # the details.
    class Rejected < Error
      attr_reader :result

      def initialize(result)
        @result = result
        super("#{result.code} #{result.message}")
      end
    end

    # The note was denied (uso denegado): its number is consumed and it can't be corrected.
    class Denied < Rejected; end

    # SEFAZ blocked the certificate/CNPJ for consuming the service improperly (cStat 656);
    # retrying before an hour has passed extends the block.
    class ConsumptionBlocked < Rejected; end

    # The key already exists at SEFAZ with different content than what was sent (e.g. cNF or
    # data changed between attempts): the earlier note is authorized and this one is not.
    class Conflict < Error; end
  end
end
