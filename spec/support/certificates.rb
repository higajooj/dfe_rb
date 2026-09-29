# Self-signed A1-style certificates generated at runtime, so no real ones are committed.
# Like ICP-Brasil e-CNPJ certificates, they name the CNPJ in the subject's CN.
module CertificateHelpers
  def self.pkcs12(password: "cert-pass", cnpj: "00000000000000", not_after: nil)
    @pkcs12 ||= {}
    @pkcs12[[password, cnpj, not_after]] ||= begin
      key = OpenSSL::PKey::RSA.new(2048)
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = 1
      cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=DFE RB TEST:#{cnpj}")
      cert.public_key = key.public_key
      cert.not_before = Time.now - 60
      cert.not_after = not_after || Time.now + 3600
      cert.sign(key, OpenSSL::Digest.new("SHA256"))
      OpenSSL::PKCS12.create(password, "test", key, cert).to_der
    end
  end

  def pkcs12_der(password: "cert-pass", cnpj: "00000000000000", not_after: nil) = CertificateHelpers.pkcs12(password:, cnpj:, not_after:)
end

RSpec.configure do |config|
  config.include CertificateHelpers
end
