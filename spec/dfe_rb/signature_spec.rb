RSpec.describe DfeRb::Signature do
  let(:certificate) { DfeRb::Certificate.from_pkcs12(pkcs12_der, "cert-pass") }
  let(:namespace) { "http://www.portalfiscal.inf.br/mdfe" }
  let(:unsigned) { %(<MDFe xmlns="#{namespace}"><infMDFe Id="MDFe1" versao="3.00"><ide><cUF>50</cUF></ide></infMDFe></MDFe>) }
  let(:signed) { described_class.sign(unsigned, certificate, namespace: namespace, container: "MDFe", signed: "infMDFe") }

  it "signs the element with the Id of a document in any namespace" do
    document = Nokogiri::XML(signed)

    expect(document.root.element_children.map(&:name)).to eq(%w[infMDFe Signature])
    expect(document.at_xpath("//ds:Reference/@URI", "ds" => described_class::DS).value).to eq("#MDFe1")
    expect(signed).to start_with(unsigned.delete_suffix("</MDFe>"))
    expect(described_class.verify(signed)).to be(true)
    expect(described_class.digest_value(signed)).to match(%r{\A[A-Za-z0-9+/]{27}=\z})
  end

  it "detects tampering" do
    expect(described_class.verify(signed.sub("<cUF>50</cUF>", "<cUF>51</cUF>"))).to eq("digest mismatch")
  end

  it "refuses what it can't sign" do
    expect { described_class.sign(signed, certificate, namespace: namespace, container: "MDFe", signed: "infMDFe") }.to raise_error(ArgumentError, /already signed/)
    expect { described_class.sign(unsigned, certificate, namespace: namespace, container: "MDFe", signed: "infEvento") }.to raise_error(ArgumentError, /no infEvento/)
    expect { described_class.sign(unsigned, certificate, namespace: "http://www.portalfiscal.inf.br/nfe", container: "MDFe", signed: "infMDFe") }
      .to raise_error(ArgumentError, /no <MDFe>/)
  end

  it "signs with SHA-256 when asked, as the NFS-e takes it" do
    sha256 = described_class.sign(unsigned, certificate, namespace: namespace, container: "MDFe", signed: "infMDFe", digest: :sha256)
    document = Nokogiri::XML(sha256)

    expect(document.at_xpath("//ds:SignatureMethod/@Algorithm", "ds" => described_class::DS).value).to eq("http://www.w3.org/2001/04/xmldsig-more#rsa-sha256")
    expect(document.at_xpath("//ds:DigestMethod/@Algorithm", "ds" => described_class::DS).value).to eq("http://www.w3.org/2001/04/xmlenc#sha256")
    expect(described_class.digest_value(sha256)).to match(%r{\A[A-Za-z0-9+/]{43}=\z})
    expect(described_class.verify(sha256)).to be(true)
    expect(described_class.verify(sha256.sub("<cUF>50</cUF>", "<cUF>51</cUF>"))).to eq("digest mismatch")
    expect(described_class.verify(sha256.sub("xmldsig-more#rsa-sha256", "xmldsig#rsa-sha1"))).to eq("the signature and digest methods differ")
  end
end
