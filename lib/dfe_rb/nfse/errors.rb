module DfeRb
  module Nfse
    class Error < DfeRb::Error; end

    # Raised by issue! when the Sefin rejected the DPS. #result has the details.
    class Rejected < Error
      attr_reader :result

      def initialize(result)
        @result = result
        super(result.errors.join("; "))
      end
    end

    # The Sefin holds an NFS-e for this DPS's Id with a different DPS inside than the one
    # sent, or answered with a note about another DPS.
    class Conflict < Error; end
  end
end
