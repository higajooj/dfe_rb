RSpec.describe DfeRb::Signer do
  let(:pkcs12) { OpenSSL::PKCS12.new(pkcs12_der, "cert-pass") }
  let(:ns) { {"ds" => "http://www.w3.org/2000/09/xmldsig#"} }
  let(:signer) do
    described_class.new(%(<evento xmlns="http://www.portalfiscal.inf.br/nfe"><infEvento Id="ID1"><a>1</a></infEvento></evento>),
      noblanks: false, wss: false, canonicalize_algorithm: :c14n_1_0).tap do |s|
      s.cert = pkcs12.certificate
      s.private_key = pkcs12.key
    end
  end
  let(:doc) do
    node = signer.document.at_css("xmlns|infEvento", xmlns: "http://www.portalfiscal.inf.br/nfe")
    signer.security_node = signer.document.root
    signer.digest! node, id: node["Id"], enveloped: true
    signer.sign!(issuer_serial: true)
    signer.document
  end

  it "is namespaced so it cannot clash with the upstream signer gem" do
    expect(defined?(::Signer)).to be_nil
  end

  it "uses the c14n 1.0 and enveloped-signature transforms NF-e requires" do
    algorithms = doc.xpath("//ds:Reference/ds:Transforms/ds:Transform/@Algorithm", ns).map(&:value)

    expect(algorithms).to eq(%w[
      http://www.w3.org/TR/2001/REC-xml-c14n-20010315
      http://www.w3.org/2000/09/xmldsig#enveloped-signature
    ])
  end

  it "references the signed element and embeds the certificate" do
    expect(doc.at_xpath("//ds:Reference", ns)["URI"]).to eq("#ID1")
    expect(doc.at_xpath("//ds:X509Certificate", ns).text.delete("\n")).to eq(Base64.strict_encode64(pkcs12.certificate.to_der))
  end
end
