RSpec.describe DfeRb::Dfe do
  let(:client) { instance_double(Savon::Client) }
  let(:soap_response) { instance_double(Savon::Response, to_xml: "<response/>") }
  let(:pkcs12) { OpenSSL::PKCS12.new(pkcs12_der, "cert-pass") }
  let(:options) { {cert: pkcs12.certificate, key: pkcs12.key, cnpj: Fixtures::HR_CNPJ, amb: "1"} }

  before do
    allow(Savon).to receive(:client).and_return(client)
    allow(client).to receive(:call).and_return(soap_response)
  end

  def request_doc(dfe) = Nokogiri::XML(dfe.request_xml).remove_namespaces!

  it "calls the production endpoint with the certificate and returns the response XML" do
    dfe = described_class.new(:broad, options)

    expect(dfe.call).to eq("<response/>")
    expect(Savon).to have_received(:client).with(hash_including(wsdl: described_class::PROD, ssl_cert: options[:cert], ssl_cert_key: options[:key]))
    expect(client).to have_received(:call).with(:nfe_dist_d_fe_interesse, xml: dfe.request_xml)
  end

  it "verifies the server certificate against system and ICP-Brasil roots" do
    described_class.new(:broad, options).call
    expect(Savon).to have_received(:client).with(hash_including(ssl_verify_mode: :peer, ssl_cert_store: DfeRb.cert_store))
  end

  it "uses the homologation endpoint outside production" do
    described_class.new(:broad, options.merge(amb: "2")).call
    expect(Savon).to have_received(:client).with(hash_including(wsdl: described_class::HOM))
  end

  it "asks for everything from NSU zero on a broad call" do
    dfe = described_class.new(:broad, options)
    dfe.call
    doc = request_doc(dfe)

    expect(doc.at_css("distDFeInt CNPJ").text).to eq(Fixtures::HR_CNPJ)
    expect(doc.at_css("distDFeInt tpAmb").text).to eq("1")
    expect(doc.at_css("distNSU ultNSU").text).to eq("000000000000000")
  end

  it "asks for documents after the given NSU" do
    dfe = described_class.new(:last_nsu, options.merge(nsu: "000000000000042"))
    dfe.call
    expect(request_doc(dfe).at_css("distNSU ultNSU").text).to eq("000000000000042")
  end

  it "asks for one NSU" do
    dfe = described_class.new(:target_nsu, options.merge(nsu: "000000000000042"))
    dfe.call
    doc = request_doc(dfe)

    expect(doc.at_css("distNSU")).to be_nil
    expect(doc.at_css("distDFeInt consNSU NSU").text).to eq("000000000000042")
  end

  it "asks for one access key" do
    dfe = described_class.new(:key, options.merge(chkey: Fixtures::ACO_KEY))
    dfe.call
    doc = request_doc(dfe)

    expect(doc.at_css("distNSU")).to be_nil
    expect(doc.at_css("distDFeInt consChNFe chNFe").text).to eq(Fixtures::ACO_KEY)
  end

  describe "logging" do
    it "logs through DfeRb.logger with sensitive and bulky elements filtered" do
      logger = Logger.new(File::NULL)
      allow(DfeRb).to receive(:logger).and_return(logger)
      described_class.new(:broad, options).call

      expect(Savon).to have_received(:client).with(hash_including(
        log: true, logger: logger, filters: include("docZip", "X509Certificate", "SignatureValue")
      ))
    end

    it "does not log without a logger" do
      allow(DfeRb).to receive(:logger).and_return(nil)
      described_class.new(:broad, options).call

      expect(Savon).to have_received(:client).with(hash_including(log: false))
    end

    it "blanks out the documents in a logged response but keeps the status" do
      logged = Savon::LogMessage.new(build_dist_response(Array.new(5) { |i| ["<resNFe><n>#{i}</n></resNFe>", "resNFe_v1.01.xsd"] }), DfeRb::LOG_FILTERS).to_s
      doc = Nokogiri::XML(logged).remove_namespaces!

      expect(doc.css("docZip").map(&:text)).to all(eq("***FILTERED***"))
      expect(doc.css("docZip").size).to eq(5)
      expect(doc.at_css("retDistDFeInt cStat").text).to eq("138")
    end
  end
end
