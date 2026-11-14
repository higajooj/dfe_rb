module DfeRb
  class Error < StandardError; end

  # The certificate can't be loaded or isn't usable (wrong password, no private key, expired...).
  class CertificateError < Error; end

  # The request never produced a usable SEFAZ answer: a TLS error, timeout, HTTP status, SOAP
  # fault or unreadable body. #maybe_processed? says whether SEFAZ may have acted on the
  # request anyway (a read timeout after sending) or certainly did not (could not connect).
  # Look up a request that may have been processed before sending it again. #http_status is
  # the HTTP status of an answer that wasn't one (403: SEFAZ refused the client certificate
  # at the TLS layer), nil when there was no answer.
  class TransportError < Error
    attr_reader :http_status

    def initialize(message = nil, maybe_processed: true, http_status: nil)
      super(message)
      @maybe_processed = maybe_processed
      @http_status = http_status
    end

    def maybe_processed? = @maybe_processed

    # SEFAZ wouldn't take the certificate the request went with.
    def certificate_refused? = http_status == 403
  end

  # Local checks failed before anything was sent. #issues lists every problem found.
  class ValidationError < Error
    attr_reader :issues

    def initialize(issues)
      @issues = Array(issues).freeze
      super("#{@issues.size} validation issue(s): #{@issues.join("; ")}")
    end
  end
end
