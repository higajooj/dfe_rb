module DfeRb
  # Emission of NFC-e (modelo 65, layout 4.00): the consumer's note. It shares the NF-e's
  # layout, signature, messages and results (DfeRb::Nfe), with its own authorizers, rules
  # and QR code.
  module Nfce
    # What the NFC-e shares with the NF-e, under its own name.
    Formatter = DfeRb::Formatter
    Requests = Nfe::Requests
    StatusCodes = Nfe::StatusCodes
    SignedInvoice = Nfe::SignedInvoice
    StatusResult = Nfe::StatusResult
    AuthorizationResult = Nfe::AuthorizationResult
    ConsultResult = Nfe::ConsultResult
    EventSummary = Nfe::EventSummary
    EventResult = Nfe::EventResult
    InutilizationResult = Nfe::InutilizationResult
    Error = Nfe::Error
    Rejected = Nfe::Rejected
    Denied = Nfe::Denied
    ConsumptionBlocked = Nfe::ConsumptionBlocked
    Conflict = Nfe::Conflict
    Unsupported = Nfe::Unsupported

    # The chave de acesso of an NFC-e: modelo 65 unless told otherwise.
    class AccessKey < Nfe::AccessKey
      def self.build(model: 65, **parts) = super
    end
  end
end

require_relative "nfce/states"
require_relative "nfce/endpoints"
require_relative "nfce/qr_code"
require_relative "nfce/supplement"
require_relative "nfce/validator"
require_relative "nfce/invoice"
require_relative "nfce/client"
