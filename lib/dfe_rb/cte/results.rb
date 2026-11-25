module DfeRb
  module Cte
    StatusResult = Data.define(:code, :message, :state_code, :received_at, :average_seconds, :returns_at, :note, :xml) do
      def online? = StatusCodes.service_up?(code)
    end

    AuthorizationResult = Data.define(
      :key, :code, :message, :protocol, :received_at, :alerts, :digest_value, :qr_code,
      :signed_xml, :protocol_xml, :response_xml, :recovered
    ) do
      def status
        if StatusCodes.authorized?(code)
          :authorized
        elsif code == StatusCodes::CANCELED
          :canceled
        else
          :rejected
        end
      end

      def authorized? = status == :authorized

      def canceled? = status == :canceled

      def rejected? = status == :rejected

      def blocked? = StatusCodes.consumption_blocked?(code)

      def recovered? = recovered

      def proc_xml
        return if protocol_xml.nil? || rejected?

        Proc.cte(signed_xml, protocol_xml)
      end

      def filename = "#{key}-procCTe.xml"
    end

    ConsultResult = Data.define(:key, :code, :message, :protocol, :received_at, :digest_value, :events, :protocol_xml, :xml) do
      def status
        if StatusCodes.authorized?(code)
          :authorized
        elsif code == StatusCodes::CANCELED
          :canceled
        elsif code == StatusCodes::NOT_FOUND
          :not_found
        else
          :rejected
        end
      end

      def authorized? = status == :authorized

      def canceled? = status == :canceled

      def found? = %i[authorized canceled].include?(status)
    end

    EventSummary = Data.define(:type, :sequence, :code, :message, :protocol, :description, :xml)

    EventResult = Data.define(:key, :type, :sequence, :code, :message, :protocol, :registered_at, :event_xml, :return_xml, :xml) do
      def registered? = StatusCodes.event_registered?(code)

      def duplicate? = code == StatusCodes::DUPLICATE_EVENT

      def blocked? = StatusCodes.consumption_blocked?(code)

      def proc_xml
        return unless registered? && return_xml

        Proc.event(event_xml, return_xml)
      end

      def filename = "#{key}_#{type}_#{format("%03d", sequence)}-procEventoCTe.xml"
    end
  end
end
