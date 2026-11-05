require_relative "nfce/states"
require_relative "nfce/endpoints"

module DfeRb
  # Emission of NFC-e (modelo 65, layout 4.00): the consumer's note. It shares the NF-e's
  # layout, signature, messages and results (DfeRb::Nfe), with its own authorizers, rules
  # and QR code.
  module Nfce
  end
end
