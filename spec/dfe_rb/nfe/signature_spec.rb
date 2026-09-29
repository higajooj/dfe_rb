RSpec.describe DfeRb::Nfe::Signature do
  let(:certificate) { nfe_certificate }
  let(:client) { nfe_client(NfeHelpers::FakeTransport.new) }
  let(:unsigned) { simples_invoice(client).to_xml }
  let(:signed) { described_class.sign_nfe(unsigned, certificate) }
  let(:ns) { {"nfe" => NfeHelpers::NFE_NS, "ds" => "http://www.w3.org/2000/09/xmldsig#"} }

  it "signs infNFe with the profile the layout schema fixes" do
    document = Nokogiri::XML(signed)
    signature = document.at_xpath("/nfe:NFe/ds:Signature", ns)
    reference = signature.at_xpath("ds:SignedInfo/ds:Reference", ns)

    expect(document.root.element_children.map(&:name)).to eq(%w[infNFe Signature])
    expect(reference["URI"]).to eq("##{document.at_xpath("//nfe:infNFe", ns)["Id"]}")
    expect(signature.at_xpath("ds:SignedInfo/ds:CanonicalizationMethod/@Algorithm", ns).value).to eq("http://www.w3.org/TR/2001/REC-xml-c14n-20010315")
    expect(signature.at_xpath("ds:SignedInfo/ds:SignatureMethod/@Algorithm", ns).value).to eq("http://www.w3.org/2000/09/xmldsig#rsa-sha1")
    expect(reference.at_xpath("ds:DigestMethod/@Algorithm", ns).value).to eq("http://www.w3.org/2000/09/xmldsig#sha1")
    expect(reference.xpath("ds:Transforms/ds:Transform/@Algorithm", ns).map(&:value)).to eq(%w[
      http://www.w3.org/2000/09/xmldsig#enveloped-signature
      http://www.w3.org/TR/2001/REC-xml-c14n-20010315
    ])
    expect(signature.at_xpath("ds:KeyInfo/ds:X509Data", ns).element_children.map(&:name)).to eq(["X509Certificate"])
    expect(signature.at_xpath("ds:KeyInfo//ds:X509Certificate", ns).text).to eq(certificate.base64)
  end

  it "verifies, also after a round trip through a parser" do
    expect(described_class.verify(signed)).to be(true)
    expect(described_class.verify(Nokogiri::XML(signed).to_xml(save_with: 0))).to be(true)
  end

  it "passes the official schema once signed" do
    expect(DfeRb::Nfe::Schemas.nfe_issues(signed)).to eq([])
  end

  it "detects tampering with the signed content or the signature" do
    expect(described_class.verify(signed.sub("<vNF>20.00</vNF>", "<vNF>21.00</vNF>"))).to eq("digest mismatch")
    tampered = signed.sub(%r{<SignatureValue>(.)}) { "<SignatureValue>#{(Regexp.last_match(1) == "A") ? "B" : "A"}" }
    expect(described_class.verify(tampered)).to eq("signature value mismatch")
  end

  it "reports what is missing" do
    expect(described_class.verify(unsigned)).to eq("no signature")
  end

  it "refuses to sign twice or something that can't be signed" do
    expect { described_class.sign_nfe(signed, certificate) }.to raise_error(ArgumentError, /already signed/)
    expect { described_class.sign_nfe("<NFe xmlns=\"#{NfeHelpers::NFE_NS}\"/>", certificate) }.to raise_error(ArgumentError, /no infNFe/)
  end

  it "exposes the digest value" do
    expect(described_class.digest_value(signed)).to match(%r{\A[A-Za-z0-9+/]{27}=\z})
  end

  it "leaves the signed bytes alone when embedded in other documents" do
    lot = DfeRb::Nfe::Requests.authorization([signed], lot_id: "1", sync: true)
    embedded = Nokogiri::XML(lot).at_xpath("//nfe:NFe", ns).to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)

    expect(lot).to include(signed)
    expect(described_class.verify(embedded)).to be(true)
  end
end
