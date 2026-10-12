RSpec.describe DfeRb::Mdfe::Distribution::Client do
  let(:certificate) { mdfe_certificate }
  let(:transport) { FakeTransport.new }
  let(:now) { Time.now }
  let(:clock) { double(now: now) }
  let(:client) { described_class.new(certificate: certificate, transport: transport, clock: clock) }
  let(:issuer) { "11222333000181" }
  let(:signed) do
    carrier = DfeRb::Mdfe::Client.new(certificate: mdfe_certificate(cnpj: issuer), uf: "SP", transport: transport)
    carrier.sign(own_cargo_manifest(carrier) { |mdfe| mdfe.issuer tax_id: issuer })
  end
  let(:manifest_xml) { DfeRb::Mdfe::Proc.mdfe(signed.xml, prot_mdfe(signed.key)) }
  let(:event_xml) do
    %(<procEventoMDFe xmlns="#{MdfeHelpers::MDFE_NS}" versao="3.00"><eventoMDFe versao="3.00"><infEvento Id="ID110112#{signed.key}01">) +
      %(<cOrgao>35</cOrgao><tpAmb>2</tpAmb><CNPJ>#{issuer}</CNPJ><chMDFe>#{signed.key}</chMDFe><dhEvento>2026-09-29T10:01:00-03:00</dhEvento>) +
      %(<tpEvento>110112</tpEvento><nSeqEvento>1</nSeqEvento><detEvento versaoEvento="3.00"><evEncMDFe><descEvento>Encerramento</descEvento>) +
      %(</evEncMDFe></detEvento></infEvento></eventoMDFe>#{ret_evento_mdfe(signed.key, type: "110112")}</procEventoMDFe>)
  end

  def response(docs = [], code: 138, last: "10", max: "20", environment: "2")
    distribution_response(docs, code: code, last: last, max: max, environment: environment)
      .gsub(DistributionHelpers::DIST_NS, MdfeHelpers::MDFE_NS).sub('versao="1.01"', 'versao="1.00"')
  end

  def payload = Nokogiri::XML(transport.calls.last.xml).remove_namespaces!

  it "asks the Ambiente Nacional for the certificate's holder, in homologação by default" do
    transport.answer(:distribution, response([], code: 137, last: "0", max: "0"))

    result = client.distribute

    expect(client).to have_attributes(environment: :homologacao, tax_id: MdfeHelpers::ISSUER)
    expect(result).to have_attributes(query: :dist_nsu, status: :empty, documents: [], retry_at: now + 3600)
    expect(transport.calls.last.xml).to eq(%(<distDFeInt xmlns="#{MdfeHelpers::MDFE_NS}" versao="1.00"><tpAmb>2</tpAmb>) +
      %(<CNPJ>#{MdfeHelpers::ISSUER}</CNPJ><distNSU><ultNSU>000000000000000</ultNSU></distNSU></distDFeInt>))
    expect(client.endpoint).to have_attributes(url: "https://mdfe-homologacao.svrs.rs.gov.br/ws/MDFeDistribuicaoDFe/MDFeDistribuicaoDFe.asmx",
      operation: "mdfeDistDFeInteresse", request_wrapper: "mdfeDistDFeInteresse", request_tag: "mdfeDadosMsg", answer: "retDistDFeInt")
  end

  it "returns manifests and events typed, with the exact XML to archive" do
    transport.answer(:distribution, response([[manifest_xml, "procMDFe_v3.00.xsd"], [event_xml, "procEventoMDFe_v3.00.xsd"]]))

    result = client.distribute(after: 8)
    manifest, event = result.documents

    expect(result).to have_attributes(status: :documents, more?: true, last_nsu: "000000000000010", retry_at: nil)
    expect(payload.at_css("ultNSU").text).to eq("000000000000008")
    expect(manifest).to have_attributes(kind: :manifest, key: signed.key, issuer_tax_id: issuer, issuer_name: "EMPRESA TESTE LTDA",
      modal: 1, start_state: "SP", end_state: "RJ", cargo_value: BigDecimal(15000), protocol: "935260000000123", code: 100,
      nsu: "000000000000001", xml: manifest_xml, filename: "#{signed.key}-procMDFe.xml")
    expect(event).to have_attributes(kind: :event, key: signed.key, type: "110112", sequence: 1, description: "Encerramento",
      author_tax_id: issuer, protocol: "935260000000999", code: 135, filename: "#{signed.key}_110112_01-procEventoMDFe.xml")
    expect(event.registered_at).to eq(Time.iso8601("2026-09-29T10:02:00-03:00"))
  end

  it "keeps a document it doesn't know" do
    other = %(<outroDoc xmlns="#{MdfeHelpers::MDFE_NS}"><chMDFe>#{signed.key}</chMDFe></outroDoc>)
    transport.answer(:distribution, response([[other, "outroDoc_v1.00.xsd"]]))

    document = client.distribute.documents.first

    expect(document).to have_attributes(kind: :unknown, key: signed.key, xml: other, filename: "000000000000001-unknown.xml")
  end

  it "fetches the document of one NSU" do
    transport.answer(:distribution, response([[manifest_xml, "procMDFe_v3.00.xsd", "000000000000042"]], last: nil, max: nil))

    result = client.fetch_nsu(42)

    expect(payload.at_css("consNSU NSU").text).to eq("000000000000042")
    expect(result.documents.first.nsu).to eq("000000000000042")
    expect { client.fetch_nsu(0) }.to raise_error(ArgumentError, /greater than zero/)
  end

  it "advises waiting an hour once there is nothing more, or when blocked" do
    transport.answer(:distribution, response([[manifest_xml, "procMDFe_v3.00.xsd"]], last: "20", max: "20"),
      response([], code: 678, last: nil, max: nil))

    expect(client.distribute).to have_attributes(more?: false, retry_at: now + 3600)
    blocked = client.distribute
    expect(blocked).to have_attributes(status: :blocked, retry_at: now + 3600)
    expect { client.distribute! }.to raise_error(DfeRb::Mdfe::ConsumptionBlocked)
  end

  it "raises on a rejection only when asked to" do
    transport.answer(:distribution, response([], code: 491, last: nil, max: nil))

    expect(client.distribute).to be_rejected
    expect { client.fetch_nsu!(1) }.to raise_error(DfeRb::Mdfe::Rejected, /491/)
  end

  it "refuses an answer it can't trust, keeping it for diagnosis" do
    mismatched = manifest_xml.sub("<chMDFe>#{signed.key}", "<chMDFe>#{document_key(58, number: 77)}")
    transport.answer(:distribution, response([[mismatched, "procMDFe_v3.00.xsd"]]), response([], environment: "1", code: 137))

    expect { client.distribute }.to raise_error(DfeRb::Mdfe::Distribution::InvalidResponse, /keys differ/) { |error|
      expect(error).to have_attributes(schema: "procMDFe_v3.00.xsd", nsu: "000000000000001", maybe_processed?: true)
    }
    expect { client.distribute }.to raise_error(DfeRb::Distribution::InvalidResponse, /environment differs/)
  end

  it "serves only the certificate's holder" do
    base = MdfeHelpers::ISSUER[0, 8] + "0002"
    branch = base + DfeRb::TaxId.cnpj_check_digits(base)

    expect(described_class.new(certificate: certificate, tax_id: branch).tax_id).to eq(branch)
    expect { described_class.new(certificate: certificate, tax_id: issuer) }.to raise_error(DfeRb::CertificateError, /does not match/)
    expect { described_class.new(certificate: nil) }.to raise_error(DfeRb::CertificateError, /DfeRb::Certificate/)
  end
end
