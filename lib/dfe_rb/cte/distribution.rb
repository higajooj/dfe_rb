require "digest"

require_relative "distribution/endpoints"
require_relative "distribution/documents"
require_relative "distribution/client"

module DfeRb
  module Cte
    module Distribution
      PACKAGE = "PL_CTeDistDFe_100"
      VERSION = "1.00"
      READER = DfeRb::Distribution::Reader.new(namespace: Signature::CTE, label: "CT-e", response_offset: "+00:00")

      InvalidResponse = DfeRb::Distribution::InvalidResponse
      DistributionResult = DfeRb::Distribution::Result
    end
  end
end
