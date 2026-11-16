RSpec.describe DfeRb::Nfe::Client do
  # RV C17-11 (rej. 166, NT 2026.007 v1.11): the SVRS alone authorizes the note of an issuer
  # without IE, whatever the state of the client that sends it.
  let(:transport) { NfeHelpers::FakeTransport.new }
  let(:client) { nfe_client(transport) }
  let(:svrs) { "https://nfe-homologacao.svrs.rs.gov.br/ws/" }
  let(:sp) { "https://homologacao.nfe.fazenda.sp.gov.br/ws/" }

  def no_ie_invoice(number: 5)
    client.build_invoice do |nfe|
      nfe.series 1
      nfe.number number
      nfe.nature_of_operation "Alienacao de ativo imobilizado"
      nfe.issuer tax_id: "11.444.777/0001-61", name: "EMPRESA TESTE LTDA", tax_regime: :normal,
        address: {street: "Rua A", number: "100", district: "Centro", city_code: "3550308", city: "Sao Paulo", state: "SP", zip: "01001000"}
      nfe.recipient cnpj: "11222333000181", name: "CLIENTE",
        address: {street: "Rua B", number: "1", district: "Centro", city_code: "3550308", city: "Sao Paulo", state: "SP", zip: "01001000"}
      nfe.item do |i|
        i.code "1"
        i.description "Maquina"
        i.ncm "84713012"
        i.cfop "5551"
        i.unit "UN"
        i.quantity 1
        i.unit_price "100.00"
        i.ibs_cbs cst: "000", class_code: "000001", base: "100.00", ibs_uf: {rate: "0.10", amount: "0.10"},
          ibs_municipal: {rate: "0", amount: "0"}, cbs: {rate: "0.90", amount: "0.90"}
      end
      nfe.payment :no_payment
    end
  end

  let(:no_ie) { client.sign(no_ie_invoice) }
  let(:with_ie) { client.sign(simples_invoice(client)) }

  it "sends the note to the SVRS, and one with IE to its state's authorizer" do
    transport.answer(:authorization, ret_env_nfe_sync(prot_nfe(no_ie.key)))
    expect(client.authorize(no_ie)).to be_authorized
    expect(transport.calls_to(:authorization).map(&:url)).to eq(["#{svrs}NfeAutorizacao/NFeAutorizacao4.asmx"])

    transport.answer(:authorization, ret_env_nfe_sync(prot_nfe(with_ie.key)))
    client.authorize(with_ie)
    expect(transport.calls_to(:authorization).last.url).to eq("#{sp}nfeautorizacao4.asmx")
  end

  it "follows an asynchronous lot of such notes to the SVRS" do
    second = client.sign(no_ie_invoice(number: 6))
    transport.answer(:authorization, ret_env_nfe)
    transport.answer(:authorization_return, ret_cons_reci_nfe([prot_nfe(no_ie.key), prot_nfe(second.key)]))

    results = client.authorize([no_ie, second])

    expect(results).to all(be_authorized)
    expect(transport.calls_to(:authorization_return).map(&:url)).to eq(["#{svrs}NfeRetAutorizacao/NFeRetAutorizacao4.asmx"])
  end

  it "keeps such notes out of a lot with others, which has one authorizer" do
    expect { client.authorize([no_ie, with_ie]) }
      .to raise_error(ArgumentError, "a lot can't mix notes of an issuer without IE (the SVRS's) with others")
    expect(transport.calls).to be_empty
  end

  it "lets such notes share a lot with others where the client's state is the SVRS's already" do
    es = nfe_client(transport, uf: "ES")
    note = es.sign(no_ie_invoice)
    other = es.sign(simples_invoice(es, number: 9))
    transport.answer(:authorization, ret_env_nfe)
    transport.answer(:authorization_return, ret_cons_reci_nfe([prot_nfe(note.key), prot_nfe(other.key)]))

    expect(es.authorize([note, other])).to all(be_authorized)
    expect(transport.calls_to(:authorization).map(&:url)).to eq(["#{svrs}NfeAutorizacao/NFeAutorizacao4.asmx"])
  end

  it "looks the key up at the SVRS after a lost answer" do
    transport.answer(:authorization, DfeRb::TransportError.new("ReadTimeout", maybe_processed: true))
    transport.answer(:consult, ->(_xml) { ret_cons_sit_nfe(no_ie.key, protocol_xml: prot_nfe(no_ie.key, digest: no_ie.digest_value)) })

    result = client.authorize(no_ie)

    expect(result).to be_recovered
    expect(transport.calls_to(:consult).map(&:url)).to eq(["#{svrs}NfeConsulta/NfeConsulta4.asmx"])
  end

  it "asks, cancels and corrects at the SVRS when told `via: :svrs`, since the key doesn't tell" do
    key = no_ie.key
    transport.answer(:consult, ret_cons_sit_nfe(key, protocol_xml: prot_nfe(key)))
    transport.answer(:event, ret_env_evento(key, type: "110111"), ret_env_evento(key, type: "110110"))

    client.consult(key, via: :svrs)
    client.cancel(key, protocol: "135260000000123", reason: "Erro na emissao da nota", via: :svrs)
    client.correct(key, text: "Correcao do endereco do destinatario", via: :svrs)

    expect(transport.calls.map(&:url)).to eq([
      "#{svrs}NfeConsulta/NfeConsulta4.asmx", "#{svrs}recepcaoevento/recepcaoevento4.asmx", "#{svrs}recepcaoevento/recepcaoevento4.asmx"
    ])
  end

  it "keeps asking the key's own state without it" do
    key = no_ie.key
    transport.answer(:consult, ret_cons_sit_nfe(key, protocol_xml: prot_nfe(key)))

    client.consult(key)

    expect(transport.calls.first.url).to eq("#{sp}nfeconsultaprotocolo4.asmx")
  end

  it "takes `via: :svrs` over a URL the client was told for the service, as for any other authorizer" do
    custom = nfe_client(transport, endpoints: {consult: "https://proxy.example/consult"})
    transport.answer(:consult, ret_cons_sit_nfe(no_ie.key, protocol_xml: prot_nfe(no_ie.key)))

    custom.consult(no_ie.key, via: :svrs)

    expect(transport.calls.first.url).to eq("https://proxy.example/consult")
  end

  it "refuses a `via` it doesn't know" do
    expect { client.consult(no_ie.key, via: :elsewhere) }.to raise_error(ArgumentError, "via must be :home, :contingency or :svrs (got :elsewhere)")
  end

  describe DfeRb::Nfe::Endpoints do
    it "pins an authorizer when asked, whatever the state's" do
      endpoint = described_class.resolve(uf: "SP", environment: :production, service: :authorization, authorizer: "SVRS")

      expect(endpoint.authorizer).to eq("SVRS")
      expect(endpoint.url).to eq("https://nfe.svrs.rs.gov.br/ws/NfeAutorizacao/NFeAutorizacao4.asmx")
    end
  end
end
