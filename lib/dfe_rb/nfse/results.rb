require "bigdecimal"

module DfeRb
  module Nfse
    # An error or alert of an API answer (MensagemProcessamento): an E-code from Anexos I
    # and II ("E0014"), its description and, sometimes, a complement.
    Message = Data.define(:code, :description, :complement) do
      # The messages under `keys` of a JSON answer, whichever case the API spells them in
      # (the Sefin writes "erros" and "erro", the ADN "Erros").
      def self.list(json, *keys)
        keys.flat_map { |key| json&.dig(key) || json&.dig(key.capitalize) }.flat_map { |value| value.is_a?(Hash) ? [value] : Array(value) }.filter_map do |entry|
          next unless entry.is_a?(Hash)

          fetch = ->(name) { entry[name] || entry[name.capitalize] }
          new(code: fetch.call("codigo"), description: fetch.call("descricao"), complement: fetch.call("complemento"))
        end
      end

      def to_s = [code, description, complement].compact.join(" ")
    end

    # The outcome of sending a DPS. A rejection is a result, not an exception: check
    # #issued? (or use issue! to raise).
    IssueResult = Data.define(:id, :key, :http_status, :processed_at, :alerts, :errors, :signed_xml, :nfse_xml, :recovered) do
      def issued? = !nfse_xml.nil?

      def rejected? = !issued?

      # The first error's code ("E0014") and description, as the other DF-e's cStat and xMotivo.
      def code = errors.first&.code

      def message = errors.first&.description

      # The Sefin already holds an NFS-e for this DPS's series and number (E0014).
      def duplicate? = errors.any? { |error| error.code == Client::DUPLICATE }

      # Whether the note was found by looking the DPS up after a lost or ambiguous answer.
      def recovered? = recovered

      # The NFS-e, read (Note), or nil.
      def note = (Note.new(nfse_xml) if issued?)

      def number = note&.number

      # The NFS-e to archive (<key>-nfse.xml): the Sefin's signed document, which carries the DPS.
      def filename = "#{key}-nfse.xml"
    end

    # A note looked up by its key (GET /nfse/{key}).
    ConsultResult = Data.define(:key, :http_status, :errors, :nfse_xml) do
      # :found, :not_found, :forbidden (the certificate's holder is no party to it) or :rejected.
      def status
        return :found if nfse_xml

        {404 => :not_found, 401 => :forbidden, 403 => :forbidden}.fetch(http_status, :rejected)
      end

      def found? = status == :found

      def note = (Note.new(nfse_xml) if nfse_xml)

      def message = errors.first&.description
    end

    # The key of the NFS-e generated from a DPS (GET /dps/{id}). Only a party to the note
    # gets the key; anyone else learns only whether it exists (Client#issued?).
    LookupResult = Data.define(:id, :key, :http_status, :errors) do
      def found? = !key.nil?

      def message = errors.first&.description
    end

    # The outcome of an event (cancellation, manifestation...). `registered?` is HTTP 201;
    # `event_xml` is then the event the Sefin generated, which carries the signed request.
    EventResult = Data.define(:key, :type, :http_status, :errors, :request_xml, :event_xml) do
      def registered? = !event_xml.nil?

      def code = errors.first&.code

      def message = errors.first&.description

      # The event to archive, one file per type.
      def filename = "#{key}_#{type}-evento.xml"
    end

    # A document the ADN distributes: an NFS-e or an event of interest to the certificate's
    # holder (or the CNPJ asked for), by NSU.
    DistributedDocument = Data.define(:nsu, :key, :kind, :event_type, :xml, :generated_at) do
      def nfse? = kind == :nfse

      def event? = kind == :event

      def filename = nfse? ? "#{key}-nfse.xml" : "#{key}_#{event_type.to_s.downcase}_#{nsu}-evento.xml"
    end

    # One answer of the ADN's distribution (GET /contribuintes/DFe/{NSU}).
    DistributionBatch = Data.define(:status, :documents, :alerts, :errors, :http_status, :query) do
      # The highest NSU received, from which to ask next; nil when nothing came.
      def last_nsu = documents.filter_map(&:nsu).max

      def found? = status == "DOCUMENTOS_LOCALIZADOS"

      # The ADN has no document after the NSU asked for (E2220), or for the key (E2240).
      def caught_up? = status == "NENHUM_DOCUMENTO_LOCALIZADO"

      def empty? = documents.empty?

      # Refused (a certificate, a proxy, a CNPJ of another root...): see `errors`.
      def rejected? = status == "REJEICAO"
    end

    # A municipality's agreement with the Sistema Nacional NFS-e (parametrização, convênio).
    Agreement = Data.define(:city, :found, :national_data, :national_issuer, :rfb_standard_issue, :man, :credit_allowed, :message) do
      def found? = found

      # The municipality shares its notes with the ADN.
      def national_data? = national_data == 1

      # Its taxpayers issue through the Sefin Nacional's public issuers and API.
      def national_issuer? = national_issuer == 1
    end

    # An ISSQN rate a municipality set for a service: whether the service is taxed there,
    # the rate, and when it applies.
    Rate = Data.define(:incidence, :rate, :starts_on, :ends_on) do
      def taxed? = incidence == "SIM"
    end

    # The rates a municipality set for a service on a competence (parametrização, aliquota).
    RatesResult = Data.define(:city, :service, :rates, :message) do
      def found? = !rates.empty?

      # The rate in force on the competence asked for, or nil.
      def rate = rates.first&.rate
    end
  end
end
