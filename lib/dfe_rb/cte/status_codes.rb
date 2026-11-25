module DfeRb
  module Cte
    module StatusCodes
      SERVICE_RUNNING = 107
      SERVICE_PAUSED = 108
      SERVICE_DOWN = 109
      SVC_ACTIVE = 113
      SVC_INACTIVE = 114

      AUTHORIZED = 100
      AUTHORIZED_LATE = 150
      CANCELED = 101
      NOT_FOUND = 217

      EVENT_REGISTERED = [135, 136, 134].freeze
      DUPLICATE_EVENT = 631

      DUPLICATE = 204
      DUPLICATE_DIFFERENT_KEY = 539
      CONSUMPTION_BLOCKED = [656, 678].freeze

      module_function

      def authorized?(code) = [AUTHORIZED, AUTHORIZED_LATE].include?(code.to_i)

      def duplicate?(code) = code.to_i == DUPLICATE

      def consumption_blocked?(code) = CONSUMPTION_BLOCKED.include?(code.to_i)

      def event_registered?(code) = EVENT_REGISTERED.include?(code.to_i)

      def service_up?(code) = [SERVICE_RUNNING, SVC_ACTIVE].include?(code.to_i)
    end
  end
end
