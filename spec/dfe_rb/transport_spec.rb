RSpec.describe DfeRb::Transport do
  let(:certificate) { DfeRb::Certificate.from_pkcs12(pkcs12_der, "cert-pass") }
  let(:transport) { described_class.new(certificate: certificate, timeouts: {read: 5}) }
  let(:endpoint) { DfeRb::Nfe::Endpoints.resolve(uf: "SP", environment: :homologacao, service: :status) }
  let(:request_xml) { %(<?xml version="1.0" encoding="UTF-8"?><consStatServ xmlns="http://www.portalfiscal.inf.br/nfe" versao="4.00"><tpAmb>2</tpAmb></consStatServ>) }
  let(:soap_response) do
    <<~XML
      <?xml version="1.0" encoding="utf-8"?>
      <soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <soap:Body>
          <nfeResultMsg xmlns="http://www.portalfiscal.inf.br/nfe/wsdl/NFeStatusServico4">
            <retConsStatServ xmlns="http://www.portalfiscal.inf.br/nfe" versao="4.00"><cStat>107</cStat></retConsStatServ>
          </nfeResultMsg>
        </soap:Body>
      </soap:Envelope>
    XML
  end

  it "posts a SOAP 1.2 envelope and returns the XML inside nfeResultMsg" do
    stub = stub_request(:post, endpoint.url)
      .with(headers: {"Content-Type" => %(application/soap+xml; charset=utf-8; action="http://www.portalfiscal.inf.br/nfe/wsdl/NFeStatusServico4/nfeStatusServicoNF")}) { |request|
        body = Nokogiri::XML(request.body)
        payload = body.at_xpath("//*[local-name()='nfeDadosMsg']")
        payload.namespace.href == "http://www.portalfiscal.inf.br/nfe/wsdl/NFeStatusServico4" &&
          payload.at_xpath("*[local-name()='consStatServ']") &&
          body.root.namespace.href == "http://www.w3.org/2003/05/soap-envelope" &&
          request.body.scan("<?xml").size == 1
      }
      .to_return(status: 200, body: soap_response)

    result = transport.post(endpoint, request_xml)

    expect(stub).to have_been_requested
    doc = Nokogiri::XML(result)
    expect(doc.root.name).to eq("retConsStatServ")
    expect(doc.root.namespace.href).to eq("http://www.portalfiscal.inf.br/nfe")
    expect(doc.at_xpath("//*[local-name()='cStat']").text).to eq("107")
  end

  it "connects with the client certificate, the ICP-Brasil store and TLS 1.2+" do
    stub_request(:post, endpoint.url).to_return(status: 200, body: soap_response)
    expect(Net::HTTP).to receive(:start).with("homologacao.nfe.fazenda.sp.gov.br", 443, hash_including(
      use_ssl: true, cert: certificate.certificate, key: certificate.private_key,
      cert_store: DfeRb.cert_store, verify_mode: OpenSSL::SSL::VERIFY_PEER,
      min_version: OpenSSL::SSL::TLS1_2_VERSION, read_timeout: 5, open_timeout: 10
    )).and_call_original

    transport.post(endpoint, request_xml)
  end

  it "sends the certificate chain so the server can build the path to its root" do
    ca = OpenSSL::X509::Certificate.new(certificate.certificate.to_pem)
    chained = DfeRb::Certificate.new(certificate: certificate.certificate, private_key: certificate.private_key, chain: [ca])
    stub_request(:post, endpoint.url).to_return(status: 200, body: soap_response)
    expect(Net::HTTP).to receive(:start).with(anything, 443, hash_including(extra_chain_cert: [ca])).and_call_original

    described_class.new(certificate: chained).post(endpoint, request_xml)
  end

  it "raises on a SOAP fault" do
    fault = <<~XML
      <soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body><soap:Fault>
        <soap:Code><soap:Value>soap:Sender</soap:Value></soap:Code>
        <soap:Reason><soap:Text xml:lang="en">Schema validation failed</soap:Text></soap:Reason>
      </soap:Fault></soap:Body></soap:Envelope>
    XML
    stub_request(:post, endpoint.url).to_return(status: 500, body: fault)

    expect { transport.post(endpoint, request_xml) }
      .to raise_error(DfeRb::TransportError, /SOAP fault: Schema validation failed/) { |error| expect(error.maybe_processed?).to be(false) }
  end

  it "raises on a non-success HTTP status without a fault" do
    stub_request(:post, endpoint.url).to_return(status: 403, body: "<html>Forbidden</html>")

    expect { transport.post(endpoint, request_xml) }
      .to raise_error(DfeRb::TransportError, /HTTP 403/) { |error| expect(error.maybe_processed?).to be(false) }
  end

  it "flags a 5xx as possibly processed" do
    stub_request(:post, endpoint.url).to_return(status: 502, body: "bad gateway")

    expect { transport.post(endpoint, request_xml) }
      .to raise_error(DfeRb::TransportError) { |error| expect(error.maybe_processed?).to be(true) }
  end

  it "reports a read timeout as possibly processed and a connect failure as not" do
    stub_request(:post, endpoint.url).to_raise(Net::ReadTimeout)
    expect { transport.post(endpoint, request_xml) }
      .to raise_error(DfeRb::TransportError, /ReadTimeout/) { |error| expect(error.maybe_processed?).to be(true) }

    stub_request(:post, endpoint.url).to_raise(Net::OpenTimeout)
    expect { transport.post(endpoint, request_xml) }
      .to raise_error(DfeRb::TransportError, /could not connect/) { |error| expect(error.maybe_processed?).to be(false) }
  end

  it "raises when the body is not a SEFAZ answer" do
    stub_request(:post, endpoint.url).to_return(status: 200, body: "<html><body>hi</body></html>")

    expect { transport.post(endpoint, request_xml) }.to raise_error(DfeRb::TransportError, /nfeResultMsg/)
  end

  it "logs requests with signature material blanked out" do
    logger = instance_double("Logger", info: nil)
    lines = []
    allow(logger).to receive(:debug) { |&block| lines << block.call }
    stub_request(:post, endpoint.url).to_return(status: 200, body: soap_response)

    described_class.new(certificate: certificate, logger: logger)
      .post(endpoint, %(<x><SignatureValue>SECRET</SignatureValue><X509Certificate>CERT</X509Certificate></x>))

    expect(lines.join).not_to include("SECRET")
    expect(lines.join).not_to include("CERT<")
    expect(lines.join).to include("[FILTERED]")
  end
end
