require "json"
require "net/http"

module DfeRb
  module Nfse
    # JSON over HTTPS with mutual TLS, as the Sefin Nacional and the ADN take it. It returns
    # every answer that is JSON, whatever its HTTP status, since the APIs answer a rejection
    # with 400 or 404 and a body saying why; the client reads them. It raises TransportError
    # when there was no such answer: a connection or TLS failure, a timeout, or an HTTP error
    # without JSON (a proxy's page, a 5xx).
    #
    # Anything responding to #request(method, url, body) and returning a Reply can stand in
    # for it (tests, proxies, retries).
    class Transport
      # status: the HTTP status. json: the parsed body (a Hash), or nil. body: the raw text.
      Reply = Data.define(:status, :json, :body) do
        def success? = status.between?(200, 299)
      end

      METHODS = {get: Net::HTTP::Get, post: Net::HTTP::Post, head: Net::HTTP::Head}.freeze
      FILTERED_PAYLOADS = /("(?:dpsXmlGZipB64|nfseXmlGZipB64|pedidoRegistroEventoXmlGZipB64|eventoXmlGZipB64|ArquivoXml|xmlGZipB64)"\s*:\s*")[^"]*(")/

      attr_reader :certificate, :timeouts

      def initialize(certificate:, timeouts: {}, logger: nil, ssl_options: DfeRb.ssl_options)
        @certificate = certificate
        @timeouts = DfeRb::Transport::DEFAULT_TIMEOUTS.merge(timeouts)
        @logger = logger
        @connection = MutualTls.new(certificate: certificate, timeouts: @timeouts, ssl_options: ssl_options)
      end

      # `body` (a Hash) goes as JSON.
      def request(method, url, body = nil)
        uri = URI(url)
        http_request = METHODS.fetch(method).new(uri)
        http_request["Accept"] = "application/json"
        if body
          http_request["Content-Type"] = "application/json"
          http_request.body = JSON.generate(body)
        end
        log(:info) { "NFS-e #{method.upcase} #{url}" }
        log(:debug) { "request: #{filter(http_request.body)}" } if body

        response = @connection.start(uri) { |http| http.request(http_request) }
        text = response.body.to_s.dup.force_encoding(Encoding::UTF_8)
        log(:debug) { "response #{response.code}: #{filter(text)}" }
        reply(uri, response.code.to_i, text, method)
      end

      private

      def reply(uri, status, text, method)
        json = parse(text)
        return Reply.new(status: status, json: json, body: text) if json || method == :head || status.between?(200, 299)

        raise TransportError.new("HTTP #{status} from #{uri.host}#{": #{text.strip[0, 200]}" unless text.strip.empty?}",
          maybe_processed: status >= 500, http_status: status)
      end

      def parse(text)
        value = JSON.parse(text)
        value.is_a?(Hash) ? value : nil
      rescue JSON::ParserError
        nil
      end

      def log(level, &block)
        target = @logger || DfeRb.logger
        target&.public_send(level, &block)
      end

      def filter(text) = text.to_s.gsub(FILTERED_PAYLOADS, '\1[FILTERED]\2')
    end
  end
end
