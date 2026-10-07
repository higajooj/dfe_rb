require "net/http"
require "openssl"
require "nokogiri"

module DfeRb
  # SOAP 1.2 over HTTPS with mutual TLS, as the SEFAZ web services expect. Sends the payload
  # in <nfeDadosMsg> and returns the XML inside <nfeResultMsg>. The national distribution
  # endpoints supply their own operation wrapper and result tag. It fetches no WSDL.
  #
  # Anything responding to #post(endpoint, xml) can stand in for it (tests, proxies, retries).
  class Transport
    DEFAULT_TIMEOUTS = {open: 10, write: 30, read: 60}.freeze
    SOAP_ENVELOPE_NAMESPACE = "http://www.w3.org/2003/05/soap-envelope"

    attr_reader :certificate, :timeouts

    def initialize(certificate:, timeouts: {}, logger: nil, ssl_options: DfeRb.ssl_options)
      @certificate = certificate
      @timeouts = DEFAULT_TIMEOUTS.merge(timeouts)
      @logger = logger
      @ssl_options = ssl_options
    end

    # endpoint: anything with #url, #namespace and #operation (see Nfe::Endpoints).
    def post(endpoint, xml)
      wrapper = endpoint.respond_to?(:request_wrapper) ? endpoint.request_wrapper : nil
      result_tag = endpoint.respond_to?(:result_tag) ? endpoint.result_tag : "nfeResultMsg"
      envelope = self.class.envelope(endpoint.namespace, xml, wrapper: wrapper)
      log(:info) { "SEFAZ #{endpoint.operation} #{endpoint.url}" }
      log(:debug) { "request: #{DfeRb.filter_xml(envelope)}" }

      body = perform(URI(endpoint.url), envelope, endpoint)
      log(:debug) { "response: #{DfeRb.filter_xml(body)}" }
      answer = endpoint.respond_to?(:answer) ? endpoint.answer : nil
      self.class.extract_result(body, result_tag: result_tag, answer: answer)
    end

    class << self
      def envelope(namespace, xml, wrapper: nil)
        payload = xml.sub(/\A\s*<\?xml[^>]*\?>\s*/, "")
        message = %(<nfeDadosMsg xmlns="#{namespace}">#{payload}</nfeDadosMsg>)
        message = %(<#{wrapper} xmlns="#{namespace}">#{message}</#{wrapper}>) if wrapper
        %(<?xml version="1.0" encoding="utf-8"?><soap12:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" ) +
          %(xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:soap12="#{SOAP_ENVELOPE_NAMESPACE}"><soap12:Body>) +
          %(#{message}</soap12:Body></soap12:Envelope>)
      end

      # Returns the XML document inside the endpoint's result tag. Raises TransportError for
      # SOAP faults and for bodies that aren't a SEFAZ answer.
      #
      # With `answer`, the document is the one element of that name, wherever it sits, because
      # each state wraps the consulta cadastro answer in its own way.
      def extract_result(body, result_tag: "nfeResultMsg", answer: nil)
        doc = Nokogiri::XML(body) { |config| config.strict.nonet }
        raise TransportError.new("response contains a DTD", maybe_processed: true) if doc.internal_subset || doc.external_subset
        if (fault = doc.at_xpath("//*[local-name()='Fault']"))
          reason = fault.at_xpath(".//*[local-name()='Text' or local-name()='faultstring']")&.text
          raise TransportError.new("SOAP fault: #{reason || fault.text.strip}", maybe_processed: false)
        end

        if answer
          found = doc.xpath("//*[local-name()='#{answer}']")
          raise TransportError.new("response has no unambiguous <#{answer}>", maybe_processed: true) unless found.size == 1

          return found.first.dup.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
        end

        results = doc.xpath("//*[local-name()='#{result_tag}']")
        result = results.first
        content = result&.element_children&.first
        unless results.size == 1 && content && result.element_children.size == 1
          raise TransportError.new("response has no unambiguous <#{result_tag}> content", maybe_processed: true)
        end

        content.dup.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
      rescue Nokogiri::XML::SyntaxError => e
        raise TransportError.new("unreadable response: #{e.message}", maybe_processed: true)
      end
    end

    private

    def perform(uri, envelope, endpoint)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = %(application/soap+xml; charset=utf-8; action="#{endpoint.namespace}/#{endpoint.operation}")
      request.body = envelope

      response = Net::HTTP.start(uri.host, uri.port, **http_options) { |http| http.request(request) }
      body = response.body.to_s.dup.force_encoding(Encoding::UTF_8)

      # SOAP faults come with HTTP 500 and are reported by extract_result.
      unless response.is_a?(Net::HTTPSuccess) || body.include?("Fault")
        raise TransportError.new("HTTP #{response.code} from #{uri.host}", maybe_processed: response.code.to_i >= 500)
      end

      body
    rescue Net::OpenTimeout, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError => e
      raise TransportError.new("could not connect to #{uri.host}: #{e.message}", maybe_processed: false)
    rescue OpenSSL::SSL::SSLError => e
      raise TransportError.new("TLS error talking to #{uri.host}: #{e.message}", maybe_processed: false)
    rescue Net::ReadTimeout, Net::WriteTimeout, EOFError, Errno::ECONNRESET, Errno::EPIPE => e
      raise TransportError.new("#{e.class.name.split("::").last} talking to #{uri.host}: #{e.message}", maybe_processed: true)
    end

    def http_options
      {
        use_ssl: true,
        cert: certificate.certificate,
        key: certificate.private_key,
        extra_chain_cert: certificate.chain.empty? ? nil : certificate.chain,
        cert_store: @ssl_options[:ssl_cert_store],
        verify_mode: (@ssl_options[:ssl_verify_mode] == :peer) ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE,
        min_version: OpenSSL::SSL::TLS1_2_VERSION,
        open_timeout: timeouts[:open],
        write_timeout: timeouts[:write],
        read_timeout: timeouts[:read]
      }
    end

    def log(level, &block)
      target = @logger || DfeRb.logger
      target&.public_send(level, &block)
    end
  end
end
