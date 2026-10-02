RSpec.describe DfeRb::Certificate do
  let(:password) { "cert-pass" }

  # An ICP-Brasil style certificate: the CNPJ (or CPF) travels in a subjectAltName otherName.
  def icp_certificate(oid:, value:, cn: "EMPRESA TESTE")
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 2
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=#{cn}")
    cert.public_key = key.public_key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600
    factory = OpenSSL::X509::ExtensionFactory.new(cert, cert)
    cert.add_extension(factory.create_extension("subjectAltName", "otherName:#{oid};UTF8:#{value}"))
    cert.sign(key, OpenSSL::Digest.new("SHA256"))
    [cert, key]
  end

  describe ".from_pkcs12" do
    it "loads the certificate and key" do
      certificate = described_class.from_pkcs12(pkcs12_der(cnpj: "11444777000161"), password)

      expect(certificate.certificate).to be_a(OpenSSL::X509::Certificate)
      expect(certificate.private_key).to be_private
      expect(certificate.valid?).to be(true)
    end

    it "explains a wrong password" do
      expect { described_class.from_pkcs12(pkcs12_der, "wrong") }
        .to raise_error(DfeRb::CertificateError, /wrong password/)
    end

    it "rejects garbage" do
      expect { described_class.from_pkcs12("not a pfx", password) }.to raise_error(DfeRb::CertificateError)
    end
  end

  describe ".from_pkcs12 with a legacy (RC2-40) file" do
    # ICP-Brasil A1 files are often encrypted with RC2-40, which OpenSSL 3 only reads through
    # its legacy provider. The file is written with the openssl CLI, exactly as the CAs do.
    def legacy_pfx(cnpj)
      require "open3"
      require "tmpdir"
      Dir.mktmpdir do |dir|
        key = OpenSSL::PKey::RSA.new(2048)
        cert = OpenSSL::X509::Certificate.new
        cert.version = 2
        cert.serial = 3
        cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=LEGACY TEST:#{cnpj}")
        cert.public_key = key.public_key
        cert.not_before = Time.now - 60
        cert.not_after = Time.now + 3600
        cert.sign(key, OpenSSL::Digest.new("SHA256"))
        File.write(File.join(dir, "key.pem"), key.to_pem)
        File.write(File.join(dir, "cert.pem"), cert.to_pem)
        _out, _, status = Open3.capture3("openssl", "pkcs12", "-export", "-legacy", "-inkey", "key.pem", "-in", "cert.pem",
          "-out", "legacy.pfx", "-passout", "pass:#{password}", chdir: dir)
        return nil unless status.success?

        File.binread(File.join(dir, "legacy.pfx"))
      rescue Errno::ENOENT
        nil
      end
    end

    it "opens it and leaves the legacy provider unloaded afterwards" do
      pfx = legacy_pfx("11444777000161")
      skip "openssl CLI with -legacy not available" unless pfx
      skip "OpenSSL builds that read RC2 without the provider need no fallback" if begin
        OpenSSL::PKCS12.new(pfx, password)
        true
      rescue OpenSSL::PKCS12::PKCS12Error
        false
      end

      modules = ENV["OPENSSL_MODULES"]
      certificate = described_class.from_pkcs12(pfx, password)

      expect(certificate.cnpj).to eq("11444777000161")
      expect(OpenSSL::Provider.provider_names).not_to include("legacy")
      expect(ENV["OPENSSL_MODULES"]).to eq(modules)
    end
  end

  it "keeps the CA chain from the PKCS#12 file" do
    key = OpenSSL::PKey::RSA.new(2048)
    ca = OpenSSL::X509::Certificate.new
    ca.version = 2
    ca.serial = 9
    ca.subject = ca.issuer = OpenSSL::X509::Name.parse("/CN=TEST CA")
    ca.public_key = key.public_key
    ca.not_before = Time.now - 60
    ca.not_after = Time.now + 3600
    ca.sign(key, OpenSSL::Digest.new("SHA256"))
    leaf = OpenSSL::PKCS12.new(pkcs12_der, password)
    der = OpenSSL::PKCS12.create(password, "test", leaf.key, leaf.certificate, [ca]).to_der

    certificate = described_class.from_pkcs12(der, password)

    expect(certificate.chain.map { |c| c.subject.to_s }).to eq(["/CN=TEST CA"])
    expect(described_class.from_pkcs12(pkcs12_der, password).chain).to eq([])
  end

  describe "#cnpj" do
    it "reads the ICP-Brasil otherName extension" do
      cert, key = icp_certificate(oid: "2.16.76.1.3.3", value: "11444777000161")
      expect(described_class.new(certificate: cert, private_key: key).cnpj).to eq("11444777000161")
    end

    it "reads an alphanumeric CNPJ" do
      cert, key = icp_certificate(oid: "2.16.76.1.3.3", value: "12ABC34501DE35")
      expect(described_class.new(certificate: cert, private_key: key).cnpj).to eq("12ABC34501DE35")
    end

    it "falls back to the subject CN suffix" do
      certificate = described_class.from_pkcs12(pkcs12_der(cnpj: "11444777000161"), password)

      expect(certificate.cnpj).to eq("11444777000161")
      expect(certificate.cnpj_root).to eq("11444777")
      expect(certificate.tax_id).to eq("11444777000161")
    end
  end

  describe "#cpf" do
    it "reads the CPF from the e-CPF extension (birth date + CPF + ...)" do
      cert, key = icp_certificate(oid: "2.16.76.1.3.1", value: "0101198052998224725000000000000000000000000")
      certificate = described_class.new(certificate: cert, private_key: key)

      expect(certificate.cpf).to eq("52998224725")
      expect(certificate.cnpj).to be_nil
    end
  end

  describe "validity" do
    it "knows when it expired" do
      expired = described_class.from_pkcs12(pkcs12_der(not_after: Time.now - 10), password)

      expect(expired).to be_expired
      expect(expired.valid?).to be(false)
      expect(expired.valid?(Time.now - 30)).to be(true)
    end
  end

  it "requires a private key" do
    cert = OpenSSL::PKCS12.new(pkcs12_der, password).certificate
    expect { described_class.new(certificate: cert, private_key: nil) }.to raise_error(DfeRb::CertificateError)
  end

  it "does not leak the key through inspect" do
    certificate = described_class.from_pkcs12(pkcs12_der, password)
    expect(certificate.inspect).not_to include("PRIVATE")
    expect(certificate.inspect).to include("expires_at")
  end
end
