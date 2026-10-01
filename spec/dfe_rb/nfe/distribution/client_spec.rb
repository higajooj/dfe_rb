RSpec.describe DfeRb::Nfe::Distribution::Client do
  let(:certificate) { nfe_certificate }
  let(:transport) { NfeHelpers::FakeTransport.new }
  let(:now) { Time.now }
  let(:clock) { double(now: now) }
  let(:client) { described_class.new(certificate: certificate, transport: transport, clock: clock) }
  let(:key) { Fixtures::ACO_KEY }
  let(:summary) { invoice_summary_xml }

  def answer(**options)
    transport.answer(:distribution, distribution_response([[summary, "resNFe_v1.01.xsd"]], **options))
  end

  def payload = Nokogiri::XML(transport.calls.last.xml).remove_namespaces!

  it "defaults to homologacao and the certificate's CNPJ with optional UF omitted" do
    answer
    result = client.distribute
    expect(client.environment).to eq(:homologacao)
    expect(client.tax_id).to eq(Fixtures::HR_CNPJ)
    expect(result.query).to eq(:dist_nsu)
    expect(payload.at_css("distNSU ultNSU").text).to eq("000000000000000")
    expect(payload.at_css("CNPJ").text).to eq(Fixtures::HR_CNPJ)
    expect(payload.at_css("cUFAutor")).to be_nil
    expect(transport.calls.last.url).to include("hom1.nfe.fazenda.gov.br/NFeDistribuicaoDFe")
  end

  it "accepts a branch of the same company and sends cUFAutor independently of national routing" do
    base = Fixtures::HR_CNPJ[0, 8] + "0002"
    branch = base + DfeRb::TaxId.cnpj_check_digits(base)
    transport.answer(:distribution, distribution_response([], code: 137, environment: "1"))
    other = described_class.new(certificate: certificate, tax_id: branch, uf: "MS", environment: :production, transport: transport)
    other.distribute(after: "42")
    expect(payload.at_css("cUFAutor").text).to eq("50")
    expect(payload.at_css("ultNSU").text).to eq("000000000000042")
    expect(payload.at_css("CNPJ").text).to eq(branch)
    expect(transport.calls.last.url).to start_with("https://www1.nfe.fazenda.gov.br/")
  end

  it "normalizes alphanumeric CNPJ" do
    cert = nfe_certificate(cnpj: "12ABC34501DE35")
    other = described_class.new(certificate: cert, tax_id: "12.abc.345/01de-35", transport: transport)
    answer
    other.distribute
    expect(payload.at_css("CNPJ").text).to eq("12ABC34501DE35")
  end

  it "supports an e-CPF and requires its exact identity" do
    cpf = "52998224725"
    cert = ecpf_certificate(cpf: cpf)
    answer
    described_class.new(certificate: cert, transport: transport).distribute
    expect(payload.at_css("CPF").text).to eq(cpf)
    expect(payload.at_css("CNPJ")).to be_nil
    expect { described_class.new(certificate: cert, tax_id: "11144477735") }.to raise_error(DfeRb::CertificateError)
  end

  it "requires a certificate object with readable holder identity" do
    expect { described_class.new(certificate: nil) }.to raise_error(DfeRb::CertificateError, /DfeRb::Certificate/)
    anonymous = DfeRb::Certificate.from_pkcs12(pkcs12_der, "cert-pass")
    expect { described_class.new(certificate: anonymous) }.to raise_error(DfeRb::ValidationError, /tax_id/)
  end

  it "rejects an invalid identity, another company, expired and not-yet-valid certificates" do
    expect { described_class.new(certificate: certificate, tax_id: "123") }.to raise_error(DfeRb::ValidationError)
    expect { described_class.new(certificate: certificate, tax_id: "11222333000181") }.to raise_error(DfeRb::CertificateError)
    expect { described_class.new(certificate: certificate, clock: double(now: certificate.expires_at + 1)) }.to raise_error(DfeRb::CertificateError)
    expect { described_class.new(certificate: certificate, clock: double(now: certificate.not_before - 1)) }.to raise_error(DfeRb::CertificateError)
    client
    allow(clock).to receive(:now).and_return(certificate.expires_at + 1)
    expect { client.distribute }.to raise_error(DfeRb::CertificateError)
    expect(transport.calls).to be_empty
  end

  it "queries one NSU or one key without a distribution group" do
    answer
    client.fetch_nsu(42)
    expect(payload.at_css("consNSU NSU").text).to eq("000000000000042")
    expect(payload.at_css("distNSU")).to be_nil
    client.fetch_key(key)
    expect(payload.at_css("consChNFe chNFe").text).to eq(key)
    expect(payload.at_css("consNSU")).to be_nil
  end

  [nil, -1, 1.5, "-1", "1e3", "", "1" * 16, "1 2"].each do |value|
    it "rejects malformed NSU #{value.inspect} without sending" do
      expect { client.distribute(after: value) }.to raise_error(ArgumentError, /NSU/)
      expect { client.fetch_nsu(value) }.to raise_error(ArgumentError, /NSU/)
      expect(transport.calls).to be_empty
    end
  end

  it "rejects zero for a targeted NSU, invalid keys and model 65" do
    model65 = DfeRb::Nfe::AccessKey.build(state: "SP", issued_at: now, tax_id: Fixtures::HR_CNPJ,
      series: 1, number: 1, numeric_code: "87654321", model: 65)
    expect { client.fetch_nsu(0) }.to raise_error(ArgumentError)
    expect { client.fetch_key("123") }.to raise_error(ArgumentError)
    expect { client.fetch_key(model65) }.to raise_error(ArgumentError, /model 55/)
    expect(transport.calls).to be_empty
  end

  it "exposes immutable results, metadata and exact XML" do
    answer
    batch = client.distribute
    document = batch.documents.first
    expect(batch).to be_frozen
    expect(batch.documents).to be_frozen
    expect(batch.response_xml).to be_frozen
    expect(document.xml).to be_frozen
    expect(document.xml).to eq(summary)
    expect(document.key).to eq(key)
    expect(document.issuer_name).to eq("Emitente & Filhos")
    expect(document.total).to eq(BigDecimal("123.45"))
    expect(document.protocol).to eq("135260000000001")
    expect(document.status).to eq(:authorized)
    expect(document.filename).to eq("#{key}-resNFe.xml")
    expect(document).to be_summary
    expect(batch.responded_at).to eq(Time.iso8601("2026-09-29T10:00:00-03:00"))
    expect(batch.request_xml).to eq(transport.calls.last.xml)
  end

  it "allows pagination only through distribution results" do
    answer
    result = client.distribute
    expect(result).to be_more
    expect(result.retry_at).to be_nil
    expect(result.last_nsu).to eq("000000000000010")
    expect(client.fetch_nsu(10)).not_to be_more
    expect(client.fetch_key(key)).not_to be_more
  end

  it "reports a one-hour delay for empty and exhausted sequential queries" do
    transport.answer(:distribution, distribution_response([], code: 137),
      distribution_response([[summary, "resNFe_v1.01.xsd"]], last: "20", max: "20"))
    empty = client.distribute
    expect(empty).to be_empty
    expect(empty).not_to be_more
    expect(empty.retry_at).to eq(now + 3600)
    exhausted = client.distribute(after: empty.last_nsu)
    expect(exhausted.retry_at).to eq(now + 3600)
    expect(exhausted).not_to be_more
    expect(transport.calls.size).to eq(2) # guidance only: never sleeps or guards calls
  end

  it "does not infer a cooldown or a sequential cursor from targeted-query exhaustion" do
    transport.answer(:distribution, distribution_response([], code: 137, last: nil, max: nil))
    expect(client.fetch_key(key).retry_at).to be_nil
    expect(client.fetch_nsu(1).retry_at).to be_nil
  end

  it "preserves cursors returned with a block and reports cooldown for every query type" do
    transport.answer(:distribution, distribution_response([], code: 656, last: "88", max: nil))
    [:distribute, :fetch_nsu, :fetch_key].each do |method|
      args = if method == :distribute
        []
      else
        [(method == :fetch_key) ? key : 1]
      end
      result = client.public_send(method, *args)
      expect(result).to be_blocked
      expect(result.last_nsu).to eq("000000000000088")
      expect(result.retry_at).to eq(now + 3600)
    end
    expect { client.distribute! }.to raise_error(DfeRb::Nfe::ConsumptionBlocked) { |e| expect(e.result).to be_blocked }
  end

  [108, 109, 489, 589, 9999].each do |code|
    it "returns ordinary SEFAZ outcome #{code} and raises only through bang methods" do
      transport.answer(:distribution, distribution_response([], code: code, last: nil, max: nil))
      result = client.distribute
      expect(result.code).to eq(code)
      expect(result.status).to eq([108, 109].include?(code) ? :unavailable : :rejected)
      expect(result.retry_at).to be_nil
      expect { client.fetch_key!(key) }.to raise_error(DfeRb::Nfe::Rejected)
    end
  end

  it "does not raise for an empty bang query" do
    transport.answer(:distribution, distribution_response([], code: 137))
    expect(client.distribute!).to be_empty
  end

  it "supports endpoint overrides and raw answers" do
    custom = described_class.new(certificate: certificate, transport: transport,
      endpoints: {distribution: "https://proxy.example/distribution", manifestation: "https://proxy.example/events"})
    answer
    expect(custom.raw(:distribution, "<raw/>")).to include("retDistDFeInt")
    expect(transport.calls.last.url).to eq("https://proxy.example/distribution")
    expect(custom.endpoint(:manifestation).url).to eq("https://proxy.example/events")
    expect { custom.endpoint(:unknown) }.to raise_error(ArgumentError)
  end

  it "preserves ambiguous transport errors and never retries" do
    error = DfeRb::TransportError.new("lost answer", maybe_processed: true)
    transport.answer(:distribution, error)
    expect { client.distribute }.to raise_error { |e| expect(e).to be(error) }
    expect(transport.calls.size).to eq(1)
  end
end
