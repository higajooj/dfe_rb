RSpec.describe "Recipient manifestation" do
  let(:certificate) { nfe_certificate }
  let(:transport) { NfeHelpers::FakeTransport.new }
  let(:client) { DfeRb::Nfe::Distribution::Client.new(certificate: certificate, transport: transport) }
  let(:key) { Fixtures::ACO_KEY }
  let(:event) { client.prepare_manifestation(key, type: :awareness) }

  DfeRb::Nfe::Distribution::Manifestations::TYPES.each do |type, (code, description)|
    it "builds, validates, signs and submits #{type}" do
      reason = (type == :not_performed) ? "Mercadoria recusada pelo destinatario" : nil
      signed = client.prepare_manifestation(key, type: type, reason: reason, at: Time.now.getlocal("-04:00"))
      expect(signed.type).to eq(code)
      expect(signed.id).to eq("ID#{code}#{key}01")
      expect(signed.occurred_at.utc_offset).to eq(-14_400)
      expect(signed.xml).to include("<descEvento>#{description}</descEvento>")
      expect(signed.xml).to include("<cOrgao>91</cOrgao>", "<CNPJ>#{Fixtures::HR_CNPJ}</CNPJ>")
      expect(DfeRb::Nfe::Signature.verify(signed.xml)).to be(true)
      transport.answer(:manifestation, manifestation_response([signed]))
      result = client.manifest(signed)
      expect(result).to be_registered
      expect(result).to be_linked
      expect(result.key).to eq(key)
      expect(result.event_xml).to eq(signed.xml)
      expect(result.proc_xml).to include(signed.xml)
      expect(DfeRb::Nfe::Signature.verify(result.proc_xml)).to be(true)
      expect(DfeRb::Nfe::Distribution::Xml.parse(result.proc_xml).root.name).to eq("procEventoNFe")
      expect(result.filename).to eq("#{key}_#{code}_01-procEventoNFe.xml")
      expect(transport.calls.last.url).to include("hom1.nfe.fazenda.gov.br/NFeRecepcaoEvento4/")
    end
  end

  it "offers a key-based convenience call and keeps array results as arrays" do
    transport.answer(:manifestation, manifestation_response([event]))
    expect(client.manifest(key, type: :awareness)).to be_a(DfeRb::Nfe::Distribution::ManifestationResult)
    expect(client.manifest([key], type: :awareness).size).to eq(1)
  end

  it "supports the second occurrence of every conclusive event, but not awareness" do
    [:confirmation, :unknown_operation, :not_performed].each do |type|
      reason = (type == :not_performed) ? "Operacao nao foi realizada" : nil
      signed = client.prepare_manifestation(key, type: type, sequence: 2, reason: reason)
      expect(signed.sequence).to eq(2)
      expect(signed.id).to end_with("02")
    end
    expect { client.prepare_manifestation(key, type: :awareness, sequence: 2) }.to raise_error(DfeRb::ValidationError)
  end

  [0, 3, "1", 1.5].each do |sequence|
    it "rejects sequence #{sequence.inspect} locally" do
      expect { client.prepare_manifestation(key, type: :confirmation, sequence: sequence) }.to raise_error(DfeRb::ValidationError)
      expect(transport.calls).to be_empty
    end
  end

  it "validates justification length, type, characters and applicable event" do
    [nil, "curto", "x" * 256, 123, "justificativa com emoji 🚫", "Justificativa com NUL\0"].each do |reason|
      expect { client.prepare_manifestation(key, type: :not_performed, reason: reason) }.to raise_error(DfeRb::ValidationError)
    end
    expect { client.prepare_manifestation(key, type: :awareness, reason: "Motivo nao aplicavel") }.to raise_error(DfeRb::ValidationError)
    expect { client.prepare_manifestation(key, type: :foo) }.to raise_error(ArgumentError)
    expect { client.manifest(key) }.to raise_error(ArgumentError, /type is required/)
    signed = client.prepare_manifestation(key, type: :not_performed, reason: "  Erro na operacao & entrega <recusada>  ")
    expect(signed.xml).to include("&amp;", "&lt;recusada&gt;")
    expect(signed.verify!).to be(signed)
  end

  it "restores exact signed bytes from storage, with optional XML declaration" do
    restored = DfeRb::Nfe::Distribution::SignedManifestation.new(xml: %(<?xml version="1.0" encoding="UTF-8"?>\n#{event.xml}))
    expect(restored.xml).to eq(event.xml)
    expect(restored.filename).to eq("#{key}_210210_01-evento.xml")
    transport.answer(:manifestation, manifestation_response([event]))
    result = client.manifest(restored)
    expect(result.event_xml).to eq(event.xml)
    expect(result.proc_xml).to include(event.xml)
  end

  it "rejects tampering and an event from another author or environment before sending" do
    tampered = DfeRb::Nfe::Distribution::SignedManifestation.new(xml: event.xml.sub(event.occurred_at.iso8601, (event.occurred_at - 86400).iso8601))
    expect { client.manifest(tampered) }.to raise_error(DfeRb::ValidationError, /signature/)
    production = DfeRb::Nfe::Distribution::Client.new(certificate: certificate, environment: :production)
    expect { client.manifest(production.prepare_manifestation(key, type: :awareness)) }.to raise_error(DfeRb::ValidationError, /environment/)
    foreign = DfeRb::Nfe::Distribution::Client.new(certificate: nfe_certificate(cnpj: "11222333000181"))
    expect { client.manifest(foreign.prepare_manifestation(key, type: :awareness)) }.to raise_error(DfeRb::ValidationError, /author/)
    expect(transport.calls).to be_empty
  end

  it "rejects unsigned, wrong-root, DTD and invalid-identity stored XML" do
    ["<evento/>", "<other/>", '<!DOCTYPE evento [<!ENTITY x "x">]><evento/>',
      event.xml.sub(event.id, "IDbad"), event.xml.sub("<cOrgao>91</cOrgao>", "<cOrgao>90</cOrgao>")].each do |xml|
      expect { DfeRb::Nfe::Distribution::SignedManifestation.new(xml: xml) }.to raise_error(DfeRb::ValidationError)
    end
  end

  it "supports e-CPF authors and alphanumeric CNPJ/access keys end to end" do
    [ecpf_certificate, nfe_certificate(cnpj: "12ABC34501DE35")].each do |cert|
      other = DfeRb::Nfe::Distribution::Client.new(certificate: cert, transport: transport)
      own_key = DfeRb::Nfe::AccessKey.build(state: "SP", issued_at: Time.now, tax_id: cert.tax_id,
        series: 1, number: 1, numeric_code: "87654321")
      prepared = other.prepare_manifestation(own_key, type: :confirmation, sequence: 2)
      expect(prepared.tax_id).to eq(cert.tax_id)
      expect(prepared.verify!).to be(prepared)
      transport.replace(:manifestation, manifestation_response([prepared]))
      expect(other.manifest(prepared)).to be_registered
    end
  end

  it "rejects a valid signature whose certificate holder is not the event author" do
    foreign = nfe_certificate(cnpj: "11222333000181")
    unsigned = DfeRb::Nfe::Distribution::Manifestations.build(key: key, type: :awareness, sequence: 1,
      reason: nil, tax_id: certificate.tax_id, environment: :homologacao, at: Time.now)
    signed = DfeRb::Nfe::Distribution::SignedManifestation.new(xml: DfeRb::Nfe::Signature.sign_event(unsigned, foreign))
    expect(DfeRb::Nfe::Signature.verify(signed.xml)).to be(true)
    expect { client.manifest(signed) }.to raise_error(DfeRb::ValidationError, /signing certificate/)
    expect(transport.calls).to be_empty
  end

  it "permits a renewed transmission certificate for the same holder" do
    original = event
    renewed = DfeRb::Certificate.from_pkcs12(pkcs12_der(password: "renewed", cnpj: certificate.tax_id), "renewed")
    expect(renewed.certificate.public_key.to_der).not_to eq(certificate.certificate.public_key.to_der)
    other = DfeRb::Nfe::Distribution::Client.new(certificate: renewed, transport: transport)
    transport.answer(:manifestation, manifestation_response([original]))
    expect(other.manifest(original).event_xml).to eq(original.xml)
  end

  it "rejects invalid explicit timestamps and unsafe signature references/transforms" do
    expect { client.prepare_manifestation(key, type: :awareness, at: false) }.to raise_error(ArgumentError, /Time/)
    expect { client.prepare_manifestation(key, type: :awareness, at: certificate.expires_at + 1) }.to raise_error(DfeRb::ValidationError, /event time/)
    expect { client.manifest(key, type: :awareness, sequence: false) }.to raise_error(DfeRb::ValidationError)
    document = Nokogiri::XML(event.xml)
    transform = document.at_xpath("//ds:Transform", DfeRb::Nfe::Signature::NAMESPACES)
    transform.add_child('<XPath xmlns="http://www.w3.org/2000/09/xmldsig#">false()</XPath>')
    [event.xml.sub("URI=\"##{event.id}\"", 'URI="#other"'), document.to_xml].each do |xml|
      expect { DfeRb::Nfe::Distribution::SignedManifestation.new(xml: xml) }.to raise_error(DfeRb::ValidationError)
    end
  end

  it "rejects overrides of prepared events, duplicate identities and invalid lot sizes or identifiers" do
    expect { client.manifest(event, type: :confirmation) }.to raise_error(ArgumentError, /override/)
    expect { client.manifest([event, event]) }.to raise_error(ArgumentError, /duplicate/)
    expect { client.manifest([]) }.to raise_error(ArgumentError)
    expect { client.manifest([event] * 21) }.to raise_error(ArgumentError)
    expect { client.manifest(event, lot_id: "not-a-number") }.to raise_error(ArgumentError, /lot_id/)
    expect(transport.calls).to be_empty
  end

  it "matches mixed, reordered answers by key/type/sequence" do
    confirmation = client.prepare_manifestation(key, type: :confirmation, sequence: 2)
    transport.answer(:manifestation, manifestation_response([confirmation, event], codes: {confirmation.identity => 136}))
    results = client.manifest([event, confirmation], lot_id: 42)
    expect(results.map(&:status)).to eq([:registered, :registered_unlinked])
    expect(results.last).to be_registered
    expect(results.last).not_to be_linked
    expect(results.last.proc_xml).to include(confirmation.xml)
    expect(transport.calls.last.xml).to include("<idLote>42</idLote>")
    expect(results).to be_frozen
  end

  it "supports a full lot of 20 events in one request" do
    events = 20.times.map do |index|
      another = DfeRb::Nfe::AccessKey.build(state: "SP", issued_at: Time.now, tax_id: Fixtures::HR_CNPJ,
        series: 1, number: index + 1, numeric_code: "87654321")
      client.prepare_manifestation(another, type: :awareness)
    end
    transport.answer(:manifestation, manifestation_response(events.reverse))
    expect(client.manifest(events).map(&:key)).to eq(events.map(&:key))
    expect(transport.calls.size).to eq(1)
  end

  [573, 575, 596, 655, 656].each do |code|
    it "returns #{code} without claiming registration or constructing a process" do
      transport.answer(:manifestation, manifestation_response([event], codes: {event.identity => code}))
      result = client.manifest(event)
      expect(result).not_to be_registered
      expect(result.proc_xml).to be_nil
      expect(result.duplicate?).to eq(code == 573)
      error = (code == 656) ? DfeRb::Nfe::ConsumptionBlocked : DfeRb::Nfe::Rejected
      expect { client.manifest!(event) }.to raise_error(error)
      expect(transport.calls.size).to eq(2)
    end
  end

  it "returns lot-level rejection for every event" do
    confirmation = client.prepare_manifestation(key, type: :confirmation)
    transport.answer(:manifestation, manifestation_response([], lot_code: 215))
    expect(client.manifest([event, confirmation]).map(&:code)).to eq([215, 215])
  end

  it "raises for missing, duplicate, foreign and conflicting event answers" do
    other = client.prepare_manifestation(key, type: :confirmation)
    [[], [event, event], [other]].each do |returned|
      xml = manifestation_response(returned)
      transport.replace(:manifestation, xml)
      expect { client.manifest(event) }.to raise_error(DfeRb::Nfe::Distribution::InvalidResponse) { |error|
        expect(error.response_xml).to eq(xml)
        expect(error).to be_maybe_processed
      }
    end
    xml = manifestation_response([event]).sub("<nSeqEvento>1</nSeqEvento>", "<nSeqEvento>2</nSeqEvento>")
    transport.replace(:manifestation, xml)
    expect { client.manifest(event) }.to raise_error(DfeRb::Nfe::Distribution::InvalidResponse)
  end

  it "requires matching response environments and registration metadata" do
    [manifestation_response([event], environment: "1"),
      manifestation_response([event]).sub(/<nProt>.*?<\/nProt>/, ""),
      manifestation_response([event]).sub(/<dhRegEvento>.*?<\/dhRegEvento>/, "")].each do |xml|
      transport.replace(:manifestation, xml)
      expect { client.manifest(event) }.to raise_error(DfeRb::Nfe::Distribution::InvalidResponse)
    end
  end

  it "preserves a lost-answer error and never retries or changes sequence" do
    error = DfeRb::TransportError.new("read timeout", maybe_processed: true)
    transport.answer(:manifestation, error)
    expect { client.manifest(event) }.to raise_error { |e| expect(e).to be(error) }
    expect(transport.calls.size).to eq(1)
    expect(transport.calls.first.xml).to include(event.xml)
  end
end
