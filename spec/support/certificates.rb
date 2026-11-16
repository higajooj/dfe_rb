# Self-signed A1-style certificates generated at runtime, so no real ones are committed.
# Like ICP-Brasil e-CNPJ certificates, they name the CNPJ in the subject's CN.
module CertificateHelpers
  # Specs travel to fixed dates with their own clocks, so a test certificate starts long before
  # any of them rather than a minute before the wall clock.
  LONG_AGO = Time.utc(2020, 1, 1)

  def self.pkcs12(password: "cert-pass", cnpj: "00000000000000", not_after: nil)
    @pkcs12 ||= {}
    @pkcs12[[password, cnpj, not_after]] ||= begin
      key = OpenSSL::PKey::RSA.new(2048)
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = 1
      cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=DFE RB TEST:#{cnpj}")
      cert.public_key = key.public_key
      cert.not_before = LONG_AGO
      cert.not_after = not_after || Time.now + 3600
      cert.sign(key, OpenSSL::Digest.new("SHA256"))
      OpenSSL::PKCS12.create(password, "test", key, cert).to_der
    end
  end

  # An ICP-Brasil style certificate: the CNPJ (or CPF) travels in a subjectAltName otherName.
  def icp_certificate(oid:, value:, cn: "EMPRESA TESTE")
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 2
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=#{cn}")
    cert.public_key = key.public_key
    cert.not_before = LONG_AGO
    cert.not_after = Time.now + 3600
    factory = OpenSSL::X509::ExtensionFactory.new(cert, cert)
    cert.add_extension(factory.create_extension("subjectAltName", "otherName:#{oid};UTF8:#{value}"))
    cert.sign(key, OpenSSL::Digest.new("SHA256"))
    [cert, key]
  end

  def pkcs12_der(password: "cert-pass", cnpj: "00000000000000", not_after: nil) = CertificateHelpers.pkcs12(password:, cnpj:, not_after:)
end

RSpec.configure do |config|
  config.include CertificateHelpers
end
