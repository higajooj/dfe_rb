RSpec.describe "Distributed documents" do
  let(:transport) { NfeHelpers::FakeTransport.new }
  let(:client) { DfeRb::Nfe::Distribution::Client.new(certificate: nfe_certificate, transport: transport) }
  let(:key) { Fixtures::ACO_KEY }

  def collect(xml, schema: "ignored.xsd", nsu: "1", **options)
    transport.replace(:distribution, distribution_response([[xml, schema, nsu]], **options))
    client.distribute.documents.first
  end

  it "identifies roots rather than the schema name and permits absent NSU/digest" do
    xml = invoice_summary_xml
    document = collect(xml, schema: "../../etc/passwd", nsu: false)
    expect(document).to be_a(DfeRb::Nfe::Distribution::InvoiceSummary)
    expect(document.schema).to eq("../../etc/passwd")
    expect(document.nsu).to be_nil
    expect(document.digest_value).to be_nil
    expect(document.xml).to eq(xml)
    expect(document.filename).to eq("#{key}-resNFe.xml")
  end

  [1, 2, 3].each do |situation|
    it "exposes invoice situation #{situation}" do
      expect(collect(invoice_summary_xml(situation: situation)).status).to eq({1 => :authorized, 2 => :denied, 3 => :canceled}[situation])
    end
  end

  it "reads full invoices without reserializing their signed contents" do
    xml = distributed_invoice_xml
    document = collect(xml)
    expect(document).to be_a(DfeRb::Nfe::Distribution::InvoiceDocument)
    expect(document.xml).to eq(xml)
    expect(document).to be_invoice
    expect(document).not_to be_summary
    expect(document.total).to eq(BigDecimal("123.45"))
    expect(document.issuer_tax_id).to eq("99888777000100")
    expect(document.recipient_tax_id).to eq(Fixtures::HR_CNPJ)
    expect(document.protocol).to eq("135260000000123")
    expect(document.code).to eq(100)
    expect(document.filename).to eq("#{key}-procNFe.xml")
  end

  it "reads legacy full invoices with date-only dEmi" do
    document = collect(distributed_invoice_xml(version: "2.00"), schema: "procNFe_v2.00.xsd")
    expect(document.kind).to eq(:invoice)
    expect(document.issued_at).to eq(Time.utc(2015, 1, 2))
  end

  it "reads event summaries of arbitrary distributed event types" do
    document = collect(event_summary_xml(type: "610600", sequence: 2))
    expect(document).to be_a(DfeRb::Nfe::Distribution::EventSummary)
    expect(document).to be_event
    expect(document).to be_summary
    expect(document.type).to eq("610600")
    expect(document.sequence).to eq(2)
    expect(document.author_tax_id).to eq("99888777000100")
    expect(document.authority).to eq("91")
    expect(document.description).to eq("Evento do Fisco")
    expect(document.registered_at.utc_offset).to eq(-10_800)
    expect(document.filename).to eq("#{key}_610600_02-resEvento.xml")
  end

  it "reads full events and their protocol, preserving bytes" do
    event = client.prepare_manifestation(key, type: :confirmation, sequence: 2)
    transport.answer(:manifestation, manifestation_response([event]))
    xml = client.manifest(event).proc_xml
    document = collect(xml)
    expect(document).to be_a(DfeRb::Nfe::Distribution::EventDocument)
    expect(document.xml).to eq(xml)
    expect(document).not_to be_summary
    expect(document.code).to eq(135)
    expect(document.description).to eq("Confirmacao da Operacao")
    expect(document.filename).to eq("#{key}_210200_02-procEventoNFe.xml")
    expect(document.protocol).to eq("135260000000999")
  end

  it "rejects conflicting invoice and event protocols" do
    invoice = distributed_invoice_xml.sub("<chNFe>#{key}</chNFe>", "<chNFe>#{"1" * 44}</chNFe>")
    expect { collect(invoice) }.to raise_error(DfeRb::Nfe::Distribution::InvalidResponse, /keys differ/)
    event = client.prepare_manifestation(key, type: :awareness)
    transport.answer(:manifestation, manifestation_response([event]))
    xml = client.manifest(event).proc_xml
    # Change only the returned sequence; the signed event remains untouched.
    xml = xml.sub("<nSeqEvento>1</nSeqEvento><dhRegEvento>", "<nSeqEvento>2</nSeqEvento><dhRegEvento>")
    expect { collect(xml) }.to raise_error(DfeRb::Nfe::Distribution::InvalidResponse, /differs/)
  end

  it "preserves unknown valid XML with deterministic, safe filenames" do
    xml = %(<futureDocument xmlns="#{DistributionHelpers::DIST_NS}" versao="9.00"><chNFe>#{key}</chNFe><new>value</new></futureDocument>)
    unknown = collect(xml, nsu: false)
    expect(unknown).to be_a(DfeRb::Nfe::Distribution::UnknownDocument)
    expect(unknown.key).to eq(key)
    expect(unknown.xml).to eq(xml)
    expect(unknown.filename).to eq("#{Digest::SHA256.hexdigest(xml)}-unknown.xml")
    expect(collect(xml, nsu: "42").filename).to eq("000000000000042-unknown.xml")
    foreign = collect('<resNFe xmlns="https://other.example"><chNFe>ignored</chNFe></resNFe>')
    expect(foreign.kind).to eq(:unknown)
    expect(foreign.key).to be_nil
  end

  it "handles mixed document batches and never manifests implicitly" do
    transport.answer(:distribution, distribution_response([
      [invoice_summary_xml, "resNFe_v1.01.xsd"], [distributed_invoice_xml, "procNFe_v4.00.xsd"],
      [event_summary_xml, "resEvento_v1.01.xsd"], ["<future/>", "future.xsd"]
    ]))
    expect(client.distribute.documents.map(&:kind)).to eq([:invoice_summary, :invoice, :event_summary, :unknown])
    expect(transport.calls_to(:manifestation)).to be_empty
  end

  it "accepts XML whitespace inside Base64" do
    xml = distribution_response([[invoice_summary_xml, "resNFe_v1.01.xsd"]])
    xml = xml.sub(/(<docZip[^>]*>)([^<]+)/) { "#{$1}\n #{$2.scan(/.{1,50}/).join("\n\t")}\n" }
    transport.answer(:distribution, xml)
    expect(client.distribute.documents.first.xml).to eq(invoice_summary_xml)
  end

  ["!invalid-base64!", Base64.strict_encode64("not-gzip")].each do |content|
    it "fails on invalid archive #{content[0, 15]} without returning a batch" do
      xml = distribution_response([[invoice_summary_xml, "resNFe_v1.01.xsd"]]).sub(/(<docZip[^>]*>)[^<]+/, "\\1#{content}")
      transport.answer(:distribution, xml)
      expect { client.distribute }.to raise_error(DfeRb::Nfe::Distribution::InvalidResponse) { |error|
        expect(error.response_xml).to eq(xml)
        expect(error.schema).to eq("resNFe_v1.01.xsd")
        expect(error.nsu).to eq("000000000000001")
        expect(error).to be_maybe_processed
      }
    end
  end

  it "rejects truncated gzip, bad CRC and trailing archives" do
    original = distribution_response([[invoice_summary_xml, "resNFe_v1.01.xsd"]])
    doc = Nokogiri::XML(original)
    zip = doc.at_xpath("//*[local-name()='docZip']")
    compressed = Base64.strict_decode64(zip.text)
    bad_crc = compressed.dup
    bad_crc.setbyte(-8, bad_crc.getbyte(-8) ^ 0xff)
    [compressed[0...-4], bad_crc, compressed + compressed].each do |bytes|
      zip.content = Base64.strict_encode64(bytes)
      transport.replace(:distribution, doc.to_xml)
      expect { client.distribute }.to raise_error(DfeRb::Nfe::Distribution::InvalidResponse)
    end
  end

  it "enforces the configurable decompressed size and allows the exact limit" do
    xml = "<large>" + "x" * 4096 + "</large>"
    transport.answer(:distribution, distribution_response([[xml, "large.xsd"]]))
    bounded = DfeRb::Nfe::Distribution::Client.new(certificate: nfe_certificate, transport: transport, max_document_bytes: 4096)
    expect { bounded.distribute }.to raise_error(DfeRb::Nfe::Distribution::InvalidResponse, /decompressed bytes/)
    exact = DfeRb::Nfe::Distribution::Client.new(certificate: nfe_certificate, transport: transport, max_document_bytes: xml.bytesize)
    expect(exact.distribute.documents.first.xml).to eq(xml)
    [0, -1, nil, 1.5].each do |limit|
      expect { DfeRb::Nfe::Distribution::Client.new(certificate: nfe_certificate, max_document_bytes: limit) }.to raise_error(ArgumentError)
    end
  end

  it "fails the entire batch if a later document is malformed" do
    xml = distribution_response([[invoice_summary_xml, "resNFe_v1.01.xsd"], ["<broken>", "broken.xsd"]])
    transport.answer(:distribution, xml)
    expect { client.distribute }.to raise_error(DfeRb::Nfe::Distribution::InvalidResponse) { |error|
      expect(error.schema).to eq("broken.xsd")
      expect(error.nsu).to eq("000000000000002")
      expect(error.response_xml).to eq(xml)
    }
    expect(transport.calls.size).to eq(1)
  end

  it "rejects DTDs, external entities and malformed amounts inside documents" do
    ['<!DOCTYPE future [<!ENTITY leak SYSTEM "file:///etc/passwd">]><future>&leak;</future>',
      '<!DOCTYPE future SYSTEM "https://example.org/test.dtd"><future/>',
      invoice_summary_xml.sub("123.45", "NaN")].each do |xml|
      expect { collect(xml) }.to raise_error(DfeRb::Nfe::Distribution::InvalidResponse)
    end
  end

  it "rejects wrong roots, namespaces, environments, duplicate fields and incoherent status/documents" do
    responses = ["<broken>", "<retDistDFeInt/>", '<!DOCTYPE x [<!ENTITY x "x">]><x/>',
      distribution_response([], code: 138), distribution_response([[invoice_summary_xml, "resNFe_v1.01.xsd"]], code: 137),
      distribution_response([], code: 137, environment: "1"),
      distribution_response([], code: 137).sub("<cStat>137</cStat>", "<cStat>137</cStat><cStat>138</cStat>"),
      distribution_response([], code: 137, last: "bad"),
      distribution_response([], code: 137).sub(/<dhResp>.*?<\/dhResp>/, ""),
      distribution_response([], code: 137).sub(/<verAplic>.*?<\/verAplic>/, "")]
    responses.each do |xml|
      transport.replace(:distribution, xml)
      expect { client.distribute }.to raise_error(DfeRb::Nfe::Distribution::InvalidResponse)
    end
  end

  it "rejects invalid event identities and ambiguous document structures" do
    [event_summary_xml(type: "../../unsafe"), event_summary_xml(sequence: 0),
      event_summary_xml(sequence: 100), invoice_summary_xml.sub("2026-09-29T09:00:00-03:00", "2026-09-29T09:00:00"),
      invoice_summary_xml.sub("2026-09-29T09:00:00-03:00", "2026-02-30T09:00:00-03:00")].each do |xml|
      expect { collect(xml) }.to raise_error(DfeRb::Nfe::Distribution::InvalidResponse)
    end
    full = distributed_invoice_xml
    info = full[/<infNFe.*?<\/infNFe>/]
    expect { collect(full.sub("</infNFe>", "</infNFe>#{info}")) }.to raise_error(DfeRb::Nfe::Distribution::InvalidResponse, /multiple/)
  end

  it "accepts 50 documents but rejects oversized response lots" do
    entries = Array.new(50) { ["<future/>", "future.xsd"] }
    transport.answer(:distribution, distribution_response(entries), distribution_response(entries + entries.first(1)))
    expect(client.distribute.documents.size).to eq(50)
    expect { client.distribute }.to raise_error(DfeRb::Nfe::Distribution::InvalidResponse, /50/)
  end
end
