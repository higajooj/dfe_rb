require "openssl"

module DfeRb
  # An ICP-Brasil A1 certificate with its private key, which SEFAZ needs for mutual TLS and
  # for XML signatures. It wraps OpenSSL objects, so an app that already holds them (from a
  # stored PFX, say) can pass them straight in.
  class Certificate
    CNPJ_OID = "2.16.76.1.3.3"
    CPF_OID = "2.16.76.1.3.1"
    # Where OpenSSL 3 installs its providers, when the openssl CLI can't say.
    MODULE_DIRS = %w[
      /usr/lib/ossl-modules /usr/lib64/ossl-modules /usr/lib/x86_64-linux-gnu/ossl-modules
      /usr/lib/aarch64-linux-gnu/ossl-modules /usr/local/lib/ossl-modules /usr/local/lib64/ossl-modules
      /opt/homebrew/lib/ossl-modules /usr/local/opt/openssl@3/lib/ossl-modules
    ].freeze

    # The holder is readable from a public X509 certificate too (restored XML signatures).
    module Identity
      module_function

      def cnpj(certificate)
        other_name(certificate, CNPJ_OID)&.slice(/\A[0-9A-Z]{12}[0-9]{2}\z/) ||
          certificate.subject.to_a.find { |name, *| name == "CN" }&.dig(1).to_s[/:([0-9A-Z]{12}[0-9]{2})\z/, 1]
      end

      def cpf(certificate) = other_name(certificate, CPF_OID)&.slice(8, 11)

      def other_name(certificate, oid)
        san = certificate.extensions.find { |extension| extension.oid == "subjectAltName" }
        return unless san

        OpenSSL::ASN1.decode(san.value_der).value.each do |name|
          next unless name.tag_class == :CONTEXT_SPECIFIC && name.tag == 0

          name_oid, value = name.value
          return value.value.first.value.to_s.dup.force_encoding(Encoding::UTF_8) if name_oid.value == oid
        end
        nil
      end
    end
    private_constant :Identity

    attr_reader :certificate, :private_key, :chain

    class << self
      # CNPJ/CPF of a public X509 certificate, without requiring its private key.
      def tax_id_of(certificate) = Identity.cnpj(certificate) || Identity.cpf(certificate)

      # Takes a PKCS#12 (.pfx / .p12) file's bytes and its password. Many ICP-Brasil A1 files
      # use RC2-40, which OpenSSL 3 only reads through its "legacy" provider. The provider is
      # loaded just long enough to open the file.
      def from_pkcs12(data, password = nil)
        pkcs12 = parse_pkcs12(data, password.to_s)
        new(certificate: pkcs12.certificate, private_key: pkcs12.key, chain: pkcs12.ca_certs)
      rescue OpenSSL::PKCS12::PKCS12Error => e
        raise CertificateError, pkcs12_error_message(e)
      end

      # PEM text holding the certificate and, in the same string or in `key`, its private key.
      def from_pem(pem, key: nil, password: nil)
        certificate = OpenSSL::X509::Certificate.new(pem)
        private_key = OpenSSL::PKey.read(key || pem, password)
        new(certificate: certificate, private_key: private_key)
      rescue OpenSSL::OpenSSLError => e
        raise CertificateError, "could not read the PEM certificate/key: #{e.message}"
      end

      private

      def parse_pkcs12(data, password)
        OpenSSL::PKCS12.new(data, password)
      rescue OpenSSL::PKCS12::PKCS12Error => e
        raise unless e.message.match?(/unsupported|RC2/i)

        with_legacy_provider(e) { OpenSSL::PKCS12.new(data, password) }
      end

      def with_legacy_provider(original_error)
        provider = begin
          load_legacy_provider
        rescue NameError, OpenSSL::OpenSSLError
          raise original_error
        end
        yield
      ensure
        provider&.unload
      end

      # Precompiled Rubies (mise, rv...) carry an OpenSSL that looks for its providers where
      # it was built, so the legacy provider is retried from the system's OpenSSL 3 modules
      # directory. OPENSSL_MODULES is set only for that load, and not at all if the user
      # already set it.
      def load_legacy_provider
        OpenSSL::Provider.load("legacy")
      rescue OpenSSL::OpenSSLError
        dir = !ENV.key?("OPENSSL_MODULES") && system_modules_dir
        raise unless dir

        begin
          ENV["OPENSSL_MODULES"] = dir
          OpenSSL::Provider.load("legacy")
        ensure
          ENV.delete("OPENSSL_MODULES")
        end
      end

      def system_modules_dir
        reported = begin
          IO.popen(["openssl", "version", "-m"], err: File::NULL, &:read)[/MODULESDIR: "([^"]+)"/, 1]
        rescue SystemCallError
          nil
        end
        [reported, *MODULE_DIRS].compact.find do |dir|
          %w[legacy.so legacy.dylib].any? { |file| File.exist?(File.join(dir, file)) }
        end
      end

      def pkcs12_error_message(error)
        if error.message.match?(/mac verify|password/i)
          "could not open the PKCS#12 file: wrong password (#{error.message})"
        else
          "could not open the PKCS#12 file (#{error.message}). Files encrypted with legacy algorithms " \
            "(RC2-40) fail on OpenSSL 3: re-export them with `openssl pkcs12 -legacy`."
        end
      end
    end

    # chain: the intermediate CA certificates, sent along in the TLS handshake so the server
    # can build the path to its ICP-Brasil root (A1 .pfx files normally carry them).
    def initialize(certificate:, private_key:, chain: [])
      raise CertificateError, "certificate is required" unless certificate.is_a?(OpenSSL::X509::Certificate)
      raise CertificateError, "private key is required" unless private_key.respond_to?(:private?) && private_key.private?

      @certificate = certificate
      @private_key = private_key
      @chain = Array(chain).freeze
    end

    # The holder's CNPJ, from the ICP-Brasil subjectAltName, or nil.
    def cnpj = @cnpj ||= Identity.cnpj(certificate)

    # First 8 characters of the CNPJ: any branch's certificate may sign for the whole company.
    def cnpj_root = cnpj&.slice(0, 8)

    # The holder's CPF (e-CPF certificates), or nil.
    def cpf
      @cpf ||= Identity.cpf(certificate)
    end

    def tax_id = cnpj || cpf

    def not_before = certificate.not_before

    def expires_at = certificate.not_after

    def valid?(at = Time.now) = at.between?(not_before, expires_at)

    def expired?(at = Time.now) = at > expires_at

    def to_der = certificate.to_der

    # The certificate as base64 without line breaks, as it goes in <X509Certificate>.
    def base64 = [to_der].pack("m0")

    def inspect = "#<#{self.class} cnpj=#{cnpj.inspect} expires_at=#{expires_at.iso8601}>"
  end
end
