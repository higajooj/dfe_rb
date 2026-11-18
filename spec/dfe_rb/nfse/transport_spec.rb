RSpec.describe DfeRb::Nfse::Transport do
  let(:certificate) { DfeRb::Certificate.from_pkcs12(pkcs12_der, "cert-pass") }
  let(:transport) { described_class.new(certificate: certificate, timeouts: {read: 5}) }
  let(:url) { "https://sefin.producaorestrita.nfse.gov.br/SefinNacional/nfse" }

  it "posts JSON and returns the parsed answer whatever its status" do
    stub = stub_request(:post, url)
      .with(headers: {"Content-Type" => "application/json", "Accept" => "application/json"}, body: {"dpsXmlGZipB64" => "H4s"}.to_json)
      .to_return(status: 400, body: {"erros" => [{"codigo" => "E1229"}]}.to_json)

    reply = transport.request(:post, url, {"dpsXmlGZipB64" => "H4s"})

    expect(stub).to have_been_requested
    expect(reply).to have_attributes(status: 400, success?: false, json: {"erros" => [{"codigo" => "E1229"}]})
  end

  it "answers a HEAD with its status alone" do
    stub_request(:head, "#{url}/x").to_return(status: 404, body: "")

    expect(transport.request(:head, "#{url}/x")).to have_attributes(status: 404, json: nil)
  end

  it "raises TransportError for an answer that isn't the API's, and when the connection fails" do
    stub_request(:get, "#{url}/a").to_return(status: 403, body: "<html>Forbidden</html>")
    stub_request(:get, "#{url}/b").to_timeout
    stub_request(:get, "#{url}/c").to_raise(Errno::ECONNREFUSED)

    expect { transport.request(:get, "#{url}/a") }.to raise_error(DfeRb::TransportError) { |error|
      expect(error).to be_certificate_refused
      expect(error).not_to be_maybe_processed
    }
    expect { transport.request(:get, "#{url}/b") }.to raise_error(DfeRb::TransportError) { |error| expect(error).not_to be_maybe_processed }
    expect { transport.request(:get, "#{url}/c") }.to raise_error(DfeRb::TransportError, /could not connect/)
  end

  it "keeps the compressed documents out of the log" do
    output = StringIO.new
    logger = Object.new
    %i[info debug].each { |level| logger.define_singleton_method(level) { |&block| output.puts(block.call) } }
    logged = described_class.new(certificate: certificate, logger: logger)
    stub_request(:post, url).to_return(status: 201, body: {"chaveAcesso" => "1", "nfseXmlGZipB64" => "SECRET"}.to_json)

    logged.request(:post, url, {"dpsXmlGZipB64" => "SECRET"})

    expect(output.string).to include("NFS-e POST #{url}", '"dpsXmlGZipB64":"[FILTERED]"', '"nfseXmlGZipB64":"[FILTERED]"')
    expect(output.string).not_to include("SECRET")
  end
end

RSpec.describe DfeRb::Nfse::Layout do
  it "accepts a series in the production package, whose pattern libxml2 misreads" do
    dps = service_declaration(layout: :v1_01).to_xml

    expect(DfeRb::Nfse::Layouts.fetch(:v1_01).dps_issues(dps)).to eq([])
    expect(DfeRb::Xsd.issues(dps, package: "nfse_1.01", file: "DPS_v1.01.xsd")).to include(a_string_matching(/\^0\{0,4\}/))
  end

  it "refuses a namespace prefix (E1228) and an unknown layout" do
    xml = service_declaration.to_xml.sub("<DPS xmlns=", "<n:DPS xmlns:n=").sub("</DPS>", "</n:DPS>")

    expect(DfeRb::Nfse::Layouts.fetch(:nt009).dps_issues(xml)).to eq(["<n:DPS>: namespace prefixes are not allowed (E1228)"])
    expect { DfeRb::Nfse::Layouts.fetch(:v9) }.to raise_error(ArgumentError, /unknown NFS-e layout/)
  end
end
