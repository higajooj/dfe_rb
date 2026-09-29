RSpec.describe DfeRb::Manifest do
  let(:pkcs12) { OpenSSL::PKCS12.new(pkcs12_der, "cert-pass") }
  let(:options) { {cert: pkcs12.certificate, key: pkcs12.key, cnpj: Fixtures::HR_CNPJ, amb: "1"} }
  let(:keys) { [Fixtures::ACO_KEY, "50201213359204000165550010000028291000149640"] }
  let(:manifest) { described_class.new(keys, options) }
  let(:doc) { Nokogiri::XML(manifest.request_xml) }
  let(:ns) { {"nfe" => "http://www.portalfiscal.inf.br/nfe", "ds" => "http://www.w3.org/2000/09/xmldsig#"} }

  it "builds one awareness event per key" do
    events = doc.xpath("//nfe:envEvento/nfe:evento", ns)
    expect(events.size).to eq(2)

    event = events.first.at_xpath("nfe:infEvento", ns)
    expect(event["Id"]).to eq("ID210210#{Fixtures::ACO_KEY}01")
    expect(event.at_xpath("nfe:chNFe", ns).text).to eq(Fixtures::ACO_KEY)
    expect(event.at_xpath("nfe:CNPJ", ns).text).to eq(Fixtures::HR_CNPJ)
    expect(event.at_xpath("nfe:tpAmb", ns).text).to eq("1")
    expect(event.at_xpath("nfe:nSeqEvento", ns).text).to eq("1")
  end

  it "signs each event with the certificate" do
    doc.xpath("//nfe:evento", ns).each do |event|
      id = event.at_xpath("nfe:infEvento", ns)["Id"]
      signature = event.at_xpath("ds:Signature", ns)

      expect(signature.at_xpath(".//ds:Reference", ns)["URI"]).to eq("##{id}")
      expect(signature.at_xpath(".//ds:X509Certificate", ns).text.delete("\n")).to eq(Base64.strict_encode64(pkcs12.certificate.to_der))
      expect(signature.at_xpath(".//ds:SignatureValue", ns).text).not_to be_empty
    end
  end

  it "leaves out the issuer serial and the template's sample event" do
    expect(doc.xpath("//ds:X509IssuerSerial", ns)).to be_empty
    expect(manifest.request_xml).not_to include("ID2102102916121135193000010655001000000015100000015101")
  end

  it "posts the request to the production endpoint" do
    client = instance_double(Savon::Client)
    allow(Savon).to receive(:client).with(hash_including(wsdl: described_class::PROD)).and_return(client)
    allow(client).to receive(:call).with(:nfe_recepcao_evento_nf, xml: manifest.request_xml)
      .and_return(instance_double(Savon::Response, to_xml: "<ok/>"))

    expect(manifest.call).to eq("<ok/>")
  end

  it "verifies the server certificate against system and ICP-Brasil roots" do
    client = instance_double(Savon::Client, call: instance_double(Savon::Response, to_xml: "<ok/>"))
    allow(Savon).to receive(:client).and_return(client)

    manifest.call
    expect(Savon).to have_received(:client).with(hash_including(
      ssl_verify_mode: :peer, ssl_cert_store: DfeRb.cert_store, ssl_cert: options[:cert], ssl_cert_key: options[:key]
    ))
  end

  it "blanks out the signature in the logged request" do
    logged = Savon::LogMessage.new(manifest.request_xml, DfeRb::LOG_FILTERS).to_s
    signatures = Nokogiri::XML(logged).xpath("//ds:Signature", ns)

    expect(signatures.size).to eq(2)
    signatures.each do |signature|
      %w[X509Certificate SignatureValue DigestValue].each do |name|
        expect(signature.at_xpath(".//ds:#{name}", ns).text).to eq("***FILTERED***")
      end
    end
    expect(logged).to include(Fixtures::ACO_KEY)
  end
end
