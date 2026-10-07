module DfeRb
  module Nfe
    # cStat values the client acts on (MOC 7.0 Anexo I §4.4 and later NTs). cStat is 3 or 4
    # digits since NT 2025.002, so codes are kept as integers.
    module StatusCodes
      SERVICE_RUNNING = 107
      SERVICE_PAUSED = 108
      SERVICE_DOWN = 109
      # Answers of an SVC's status service (Anexo III 2.1.3.4 g).
      SVC_DEACTIVATING = 113
      SVC_DISABLED = 114
      # Consulta cadastro: one registration found, or more than one.
      TAXPAYER_FOUND = [111, 112].freeze

      BATCH_RECEIVED = 103
      BATCH_PROCESSED = 104
      BATCH_PROCESSING = 105
      BATCH_NOT_FOUND = 106

      AUTHORIZED = 100
      AUTHORIZED_LATE = 150
      AUTHORIZED_WITH_ALERT = 120
      DENIED = [110, 301, 302, 303].freeze
      CANCELED = 101
      CANCELED_LATE = [151, 155].freeze
      UNUSED_NUMBERS_APPROVED = 102

      EVENT_BATCH_PROCESSED = 128
      EVENT_REGISTERED = [135, 136, 155].freeze

      DUPLICATE = 204
      DUPLICATE_DIFFERENT_KEY = 539
      DUPLICATE_UNUSED_NUMBERS = 563
      CONSUMPTION_BLOCKED = 656

      AUTHORIZED_CODES = [AUTHORIZED, AUTHORIZED_LATE, AUTHORIZED_WITH_ALERT].freeze

      module_function

      def authorized?(code) = AUTHORIZED_CODES.include?(code.to_i)

      def denied?(code) = DENIED.include?(code.to_i)

      # Codes meaning "this number/key was already used by an earlier request", which is the
      # answer to a retry after a lost response. The client resolves them by asking SEFAZ
      # about the key.
      def duplicate?(code) = [DUPLICATE, DUPLICATE_DIFFERENT_KEY].include?(code.to_i)

      def consumption_blocked?(code) = code.to_i == CONSUMPTION_BLOCKED

      def event_registered?(code) = EVENT_REGISTERED.include?(code.to_i)

      def canceled?(code) = ([CANCELED] + CANCELED_LATE).include?(code.to_i)

      def service_up?(code) = code.to_i == SERVICE_RUNNING
    end
  end
end
