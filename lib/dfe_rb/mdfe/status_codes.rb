module DfeRb
  module Mdfe
    # cStat values the client acts on (MOC MDF-e 3.00b). cStat is 3 or 4 digits since
    # NT 2025.001, so codes are kept as integers.
    module StatusCodes
      SERVICE_RUNNING = 107
      SERVICE_PAUSED = 108
      SERVICE_DOWN = 109

      AUTHORIZED = 100
      CANCELED = 101
      CLOSED = 132
      NOT_FOUND = 217

      # Consulta não encerrados: some found, none found.
      UNCLOSED_FOUND = 111
      UNCLOSED_NONE = 112

      # Registered and linked, registered while the manifest wasn't there to link to, and
      # registered on a manifest that is no longer just authorized (MOC 5.1.7).
      EVENT_REGISTERED = [135, 136, 134].freeze
      DUPLICATE_EVENT = 631

      DUPLICATE = 204
      DUPLICATE_DIFFERENT_KEY = 539
      CONSUMPTION_BLOCKED = 678
      # A manifest left open that stops a new one (F85 to F88).
      UNCLOSED_BLOCKING = [462, 610, 611, 662, 686].freeze

      module_function

      def authorized?(code) = code.to_i == AUTHORIZED

      # Codes meaning "this number/key was already used by an earlier request", which is the
      # answer to a retry after a lost response. The client resolves them by asking SEFAZ
      # about the key.
      def duplicate?(code) = [DUPLICATE, DUPLICATE_DIFFERENT_KEY].include?(code.to_i)

      def consumption_blocked?(code) = code.to_i == CONSUMPTION_BLOCKED

      def unclosed_blocking?(code) = UNCLOSED_BLOCKING.include?(code.to_i)

      def event_registered?(code) = EVENT_REGISTERED.include?(code.to_i)

      def service_up?(code) = code.to_i == SERVICE_RUNNING
    end
  end
end
