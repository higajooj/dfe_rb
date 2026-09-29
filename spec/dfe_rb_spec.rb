RSpec.describe DfeRb do
  describe ".cert_store" do
    let(:icp_roots) do
      File.read(DfeRb::CA_BUNDLE).scan(/-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----/m)
        .map { |pem| OpenSSL::X509::Certificate.new(pem) }
    end

    it "trusts the bundled ICP-Brasil roots" do
      expect(icp_roots.map { |c| c.subject.to_a.assoc("CN")[1] }).to include("Autoridade Certificadora Raiz Brasileira v10")
      icp_roots.each { |root| expect(described_class.cert_store.verify(root)).to be(true), root.subject.to_s }
    end

    it "rejects a certificate from an unknown issuer" do
      cert = OpenSSL::PKCS12.new(pkcs12_der, "cert-pass").certificate
      expect(described_class.cert_store.verify(cert)).to be(false)
    end

    it "builds the store once" do
      expect(described_class.cert_store).to be(described_class.cert_store)
    end
  end

  describe ".ssl_options" do
    it "turns on peer verification with the store" do
      expect(described_class.ssl_options).to eq(ssl_verify_mode: :peer, ssl_cert_store: described_class.cert_store)
    end
  end
end
