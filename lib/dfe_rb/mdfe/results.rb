module DfeRb
  module Mdfe
    # SEFAZ answered the status query. `online?` is cStat 107.
    StatusResult = Data.define(:code, :message, :state_code, :received_at, :average_seconds, :returns_at, :note, :xml) do
      def online? = StatusCodes.service_up?(code)
    end

    # The outcome of authorizing one MDF-e. Rejections are results, not exceptions: check
    # #authorized? (or use authorize! to raise).
    AuthorizationResult = Data.define(
      :key, :code, :message, :protocol, :received_at, :alerts, :digest_value,
      :signed_xml, :protocol_xml, :response_xml, :recovered
    ) do
      # :authorized, :canceled, :closed or :rejected. :canceled and :closed only come from a
      # recovery: the manifest was authorized, and then canceled or closed.
      def status
        case code
        when StatusCodes::AUTHORIZED then :authorized
        when StatusCodes::CANCELED then :canceled
        when StatusCodes::CLOSED then :closed
        else :rejected
        end
      end

      def authorized? = status == :authorized

      def canceled? = status == :canceled

      def closed? = status == :closed

      def rejected? = status == :rejected

      def blocked? = StatusCodes.consumption_blocked?(code)

      # Whether a manifest the issuer left open is what stopped this one.
      def unclosed? = StatusCodes.unclosed_blocking?(code)

      # Whether the answer was found by looking the key up after a lost or ambiguous response.
      def recovered? = recovered

      # The mdfeProc to archive (<key>-procMDFe.xml): the signed MDFe and its protocol. Also
      # produced for canceled and closed manifests, which SEFAZ keeps.
      def proc_xml
        return if protocol_xml.nil? || rejected?

        Proc.mdfe(signed_xml, protocol_xml)
      end

      def filename = "#{key}-procMDFe.xml"
    end

    # The situation of a key at SEFAZ (consult).
    ConsultResult = Data.define(:key, :code, :message, :protocol, :received_at, :digest_value, :events, :protocol_xml, :xml) do
      # :authorized, :canceled, :closed, :not_found or :rejected.
      def status
        case code
        when StatusCodes::AUTHORIZED then :authorized
        when StatusCodes::CANCELED then :canceled
        when StatusCodes::CLOSED then :closed
        when StatusCodes::NOT_FOUND then :not_found
        else :rejected
        end
      end

      def authorized? = status == :authorized

      def canceled? = status == :canceled

      def closed? = status == :closed

      # Whether SEFAZ holds the manifest, in whatever situation.
      def found? = %i[authorized canceled closed].include?(status)
    end

    # An event SEFAZ recorded for a manifest (from a consult).
    EventSummary = Data.define(:type, :sequence, :code, :message, :protocol, :description, :xml)

    # A manifest the issuer has yet to close.
    UnclosedManifest = Data.define(:key, :protocol)

    # The issuer's manifests still open (consulta não encerrados).
    UnclosedResult = Data.define(:code, :message, :manifests, :xml) do
      def success? = [StatusCodes::UNCLOSED_FOUND, StatusCodes::UNCLOSED_NONE].include?(code)

      def any? = manifests.any?

      def none? = success? && manifests.empty?
    end

    # The outcome of an event (cancellation, closing...). `registered?` is cStat 135/136/134.
    EventResult = Data.define(:key, :type, :sequence, :code, :message, :protocol, :registered_at, :event_xml, :return_xml, :xml) do
      def registered? = StatusCodes.event_registered?(code)

      # The very event was already registered (cStat 631), as a retry after a lost answer finds.
      def duplicate? = code == StatusCodes::DUPLICATE_EVENT

      def blocked? = StatusCodes.consumption_blocked?(code)

      # procEventoMDFe to archive: the signed event and SEFAZ's registration.
      def proc_xml
        return unless registered? && return_xml

        Proc.event(event_xml, return_xml)
      end

      # One file per event, so every driver and document inclusion is kept.
      def filename = "#{key}_#{type}_#{format("%02d", sequence)}-procEventoMDFe.xml"
    end
  end
end
