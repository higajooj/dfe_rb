module DfeRb
  module Nfe
    # SEFAZ answered the status query. `online?` is cStat 107.
    StatusResult = Data.define(:code, :message, :state_code, :received_at, :average_seconds, :xml) do
      def online? = StatusCodes.service_up?(code)

      # An SVC about to stop taking the state's notes (cStat 113); it still answers.
      def deactivating? = code == StatusCodes::SVC_DEACTIVATING

      # An SVC the state's SEFAZ hasn't activated (cStat 114).
      def disabled? = code == StatusCodes::SVC_DISABLED
    end

    # The outcome of authorizing one NF-e. Rejections are results, not exceptions: check
    # #authorized? (or use authorize! to raise).
    AuthorizationResult = Data.define(
      :key, :code, :message, :protocol, :received_at, :alerts, :digest_value,
      :signed_xml, :protocol_xml, :response_xml, :receipt, :recovered
    ) do
      # :authorized, :authorized_late, :authorized_with_alert, :canceled, :denied, :pending or
      # :rejected. :canceled only comes from a recovery: the note was authorized, then canceled.
      def status
        case code
        when StatusCodes::AUTHORIZED then :authorized
        when StatusCodes::AUTHORIZED_LATE then :authorized_late
        when StatusCodes::AUTHORIZED_WITH_ALERT then :authorized_with_alert
        when *StatusCodes::DENIED then :denied
        when StatusCodes::BATCH_RECEIVED, StatusCodes::BATCH_PROCESSING then :pending
        when StatusCodes::CANCELED, *StatusCodes::CANCELED_LATE then :canceled
        else :rejected
        end
      end

      def authorized? = StatusCodes.authorized?(code)

      def canceled? = status == :canceled

      def denied? = status == :denied

      def pending? = status == :pending

      def rejected? = status == :rejected

      def blocked? = StatusCodes.consumption_blocked?(code)

      # Whether the answer was found by looking the key up after a lost or ambiguous response.
      def recovered? = recovered

      # The nfeProc to archive and hand to the recipient (<key>-procNFe.xml): the signed NFe
      # and its protocol. Also produced for denied and canceled notes, which SEFAZ keeps.
      def proc_xml
        return if protocol_xml.nil? || !(authorized? || denied? || canceled?)

        Proc.nfe(signed_xml, protocol_xml)
      end

      def filename = "#{key}-procNFe.xml"
    end

    # The situation of a key at SEFAZ (consult).
    ConsultResult = Data.define(:key, :code, :message, :protocol, :received_at, :digest_value, :events, :protocol_xml, :xml) do
      # :authorized, :authorized_late, :authorized_with_alert, :canceled, :denied, :not_found or :rejected.
      def status
        case code
        when StatusCodes::AUTHORIZED then :authorized
        when StatusCodes::AUTHORIZED_LATE then :authorized_late
        when StatusCodes::AUTHORIZED_WITH_ALERT then :authorized_with_alert
        when *StatusCodes::DENIED then :denied
        when 217 then :not_found
        else
          StatusCodes.canceled?(code) ? :canceled : :rejected
        end
      end

      def authorized? = StatusCodes.authorized?(code)

      def canceled? = status == :canceled

      def denied? = status == :denied

      def found? = status != :not_found
    end

    # An event SEFAZ recorded for a note (from a consult).
    EventSummary = Data.define(:type, :sequence, :code, :message, :protocol, :description, :xml)

    # The outcome of an event (cancellation, correction...). `registered?` is cStat 135/136/155.
    EventResult = Data.define(:key, :type, :sequence, :code, :message, :protocol, :event_xml, :return_xml, :xml) do
      def registered? = StatusCodes.event_registered?(code)

      # procEventoNFe to archive: the signed event and SEFAZ's registration.
      def proc_xml
        return unless registered? && return_xml

        Proc.event(event_xml, return_xml)
      end

      # One file per event: each CC-e sequence is kept.
      def filename = "#{key}_#{type}_#{format("%02d", sequence)}-procEventoNFe.xml"
    end

    # The outcome of an inutilização request. `approved?` is cStat 102.
    InutilizationResult = Data.define(:code, :message, :protocol, :request_xml, :return_xml, :xml) do
      def approved? = code == StatusCodes::UNUSED_NUMBERS_APPROVED

      def proc_xml
        return unless approved? && return_xml

        Proc.inutilization(request_xml, return_xml)
      end
    end
  end
end
