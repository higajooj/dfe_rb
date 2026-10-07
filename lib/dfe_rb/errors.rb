module DfeRb
  class Error < StandardError; end

  # The certificate can't be loaded or isn't usable (wrong password, no private key, expired...).
  class CertificateError < Error; end

  # The request never produced a usable SEFAZ answer: a TLS error, timeout, HTTP status, SOAP
  # fault or unreadable body. #maybe_processed? says whether SEFAZ may have acted on the
  # request anyway (a read timeout after sending) or certainly did not (could not connect).
  # Look up a request that may have been processed before sending it again.
  class TransportError < Error
    def initialize(message = nil, maybe_processed: true)
      super(message)
      @maybe_processed = maybe_processed
    end

    def maybe_processed? = @maybe_processed
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
