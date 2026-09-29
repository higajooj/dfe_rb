require "nokogiri"
require "date"
require "time"
require "openssl"

require_relative "dfe_rb/version"

module DfeRb
  # Elements blanked out of logged SOAP bodies: docZip holds the (large) compressed
  # documents, the others are signature material from signed events.
  LOG_FILTERS = %w[docZip X509Certificate SignatureValue DigestValue].freeze

  CA_BUNDLE = File.expand_path("dfe_rb/certs/icp-brasil.pem", __dir__)

  class << self
    attr_accessor :logger

    # System roots plus ICP-Brasil, which some SEFAZ endpoints chain to and
    # which isn't in OS trust stores.
    def cert_store
      @cert_store ||= OpenSSL::X509::Store.new.tap do |store|
        store.set_default_paths
        store.add_file(CA_BUNDLE)
      end
    end

    def ssl_options
      {ssl_verify_mode: :peer, ssl_cert_store: cert_store}
    end

    # The XML with the text of LOG_FILTERS elements blanked out, safe to log.
    def filter_xml(xml)
      names = LOG_FILTERS.join("|")
      xml.gsub(%r{(<(?:\w+:)?(?:#{names})(?:\s[^>]*)?>)[^<]*(</)}m, '\1[FILTERED]\2')
    end
  end
end

require_relative "dfe_rb/errors"
require_relative "dfe_rb/environment"
require_relative "dfe_rb/tax_id"
require_relative "dfe_rb/certificate"
require_relative "dfe_rb/signer"
require_relative "dfe_rb/transport"
require_relative "dfe_rb/nfe"
