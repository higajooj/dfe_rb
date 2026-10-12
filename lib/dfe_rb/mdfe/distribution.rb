require "digest"

require_relative "distribution/documents"
require_relative "distribution/client"

module DfeRb
  module Mdfe
    # MDF-e and their events of interest to someone who didn't issue them (those named in
    # autXML among them), through the Ambiente Nacional's MDFeDistribuicaoDFe (NT 2015.002).
    module Distribution
      PACKAGE = "PL_MDFeDistDFe_100"
      VERSION = "1.00"
      READER = DfeRb::Distribution::Reader.new(namespace: Signature::MDFE, label: "MDF-e")

      # An unusable answer, not an ordinary SEFAZ rejection (DfeRb::Distribution::InvalidResponse).
      InvalidResponse = DfeRb::Distribution::InvalidResponse
      # The answer to a distribution request (DfeRb::Distribution::Result).
      DistributionResult = DfeRb::Distribution::Result
    end
  end
end
