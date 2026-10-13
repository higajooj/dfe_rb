module DfeRb
  module Mdfe
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

    # SEFAZ blocked the certificate/CNPJ for consuming the service improperly (cStat 678);
    # the block lasts up to an hour and repeating the request renews it (MOC 8.2).
    class ConsumptionBlocked < Rejected; end

    # The issuer has a manifest still open that stops this one (cStat 462, 610, 611, 662,
    # 686). Close it (Client#unclosed lists them) and send again.
    class Unclosed < Rejected; end

    # The key already exists at SEFAZ with different content than what was sent (the earlier
    # manifest is authorized and this one is not), or SEFAZ's protocol is about another
    # manifest than the one sent.
    class Conflict < Error; end
  end
end
