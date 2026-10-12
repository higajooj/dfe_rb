RSpec.describe DfeRb::Mdfe::Client, "events" do
  let(:transport) { FakeTransport.new }
  let(:clock) { class_double(Time, now: Time.new(2026, 10, 12, 15, 0, 0, "+00:00")) }
  let(:client) { mdfe_client(transport, clock: clock) }
  let(:key) { document_key(58, tax_id: MdfeHelpers::ISSUER) }
  let(:protocol) { "935260000000123" }
  let(:sent) { transport.calls.first.xml }

  def detail(xml) = xml[%r{<detEvento versaoEvento="3.00">(.*)</detEvento>}m, 1]

  describe "#cancel" do
    before { transport.answer(:event, ret_evento_mdfe(key, type: "110111")) }

    it "signs and registers the cancellation, one event per call" do
      result = client.cancel(key, protocol: protocol, reason: "Erro na emissao do manifesto")

      expect(result).to be_registered
      expect(result).to have_attributes(type: "110111", sequence: 1, protocol: "935260000000999", registered_at: "2026-09-29T10:02:00-03:00")
      expect(sent).to start_with(%(<eventoMDFe xmlns="#{MdfeHelpers::MDFE_NS}" versao="3.00"><infEvento Id="ID110111#{key}01"><cOrgao>35</cOrgao><tpAmb>2</tpAmb>) +
        %(<CNPJ>#{MdfeHelpers::ISSUER}</CNPJ><chMDFe>#{key}</chMDFe><dhEvento>2026-10-12T12:00:00-03:00</dhEvento><tpEvento>110111</tpEvento><nSeqEvento>1</nSeqEvento>))
      expect(detail(sent)).to eq("<evCancMDFe><descEvento>Cancelamento</descEvento><nProt>#{protocol}</nProt><xJust>Erro na emissao do manifesto</xJust></evCancMDFe>")
      expect(DfeRb::Mdfe::Signature.verify(sent)).to be(true)
      expect(transport.calls.first.url).to end_with("/MDFeRecepcaoEvento/MDFeRecepcaoEvento.asmx")
    end

    it "gives the procEventoMDFe to archive" do
      result = client.cancel(key, protocol: protocol, reason: "Erro na emissao do manifesto")

      expect(result.filename).to eq("#{key}_110111_01-procEventoMDFe.xml")
      expect(result.proc_xml).to eq(%(<?xml version="1.0" encoding="UTF-8"?><procEventoMDFe xmlns="#{MdfeHelpers::MDFE_NS}" versao="3.00">#{sent}#{ret_evento_mdfe(key, type: "110111")}</procEventoMDFe>))
    end

    it "checks the reason and the protocol before sending" do
      expect { client.cancel(key, protocol: protocol, reason: "curto") }.to raise_error(ArgumentError, /15 to 255 characters/)
      expect { client.cancel(key, protocol: "123", reason: "Erro na emissao do manifesto") }.to raise_error(ArgumentError, "protocol must have 15 digits")
      expect { client.cancel(document_key(55), protocol: protocol, reason: "Erro na emissao do manifesto") }.to raise_error(ArgumentError, /not an MDF-e key/)
      expect(transport.calls).to be_empty
    end
  end

  it "returns a rejection as a result" do
    transport.answer(:event, ret_evento_mdfe(key, type: "110111", code: 220, message: "Rejeicao: MDF-e autorizado ha mais de 24 horas", protocol: nil),
      ret_evento_mdfe(key, type: "110111", code: 631, message: "Rejeicao: Duplicidade de evento", protocol: nil))

    rejected = client.cancel(key, protocol: protocol, reason: "Erro na emissao do manifesto")

    expect(rejected).to have_attributes(registered?: false, code: 220, protocol: nil, proc_xml: nil)
    expect(client.cancel(key, protocol: protocol, reason: "Erro na emissao do manifesto")).to be_duplicate
  end

  describe "#close" do
    before { transport.answer(:event, ret_evento_mdfe(key, type: "110112")) }

    it "closes the manifest where the trip ended, today in the issuer's state" do
      result = client.close(key, protocol: protocol, city: "Rio de Janeiro", state: "RJ")

      expect(result).to be_registered
      expect(detail(sent)).to eq("<evEncMDFe><descEvento>Encerramento</descEvento><nProt>#{protocol}</nProt><dtEnc>2026-10-12</dtEnc><cUF>33</cUF><cMun>3304557</cMun></evEncMDFe>")
    end

    it "takes a city code, a day and a trip that ended abroad" do
      client.close(key, protocol: protocol, city: "3304557", on: Date.new(2026, 10, 11))
      client.close(key, protocol: protocol, city: :exterior)

      expect(detail(sent)).to include("<dtEnc>2026-10-11</dtEnc><cUF>33</cUF><cMun>3304557</cMun>")
      expect(detail(transport.calls.last.xml)).to include("<cUF>99</cUF><cMun>9999999</cMun>")
    end

    it "refuses a city the IBGE table lacks" do
      expect { client.close(key, protocol: protocol, city: "Rio de Janero", state: "RJ") }.to raise_error(ArgumentError, /no city called/)
    end
  end

  describe "#add_driver" do
    it "adds a driver, numbering the inclusions" do
      transport.answer(:event, ret_evento_mdfe(key, type: "110114", sequence: 2))

      result = client.add_driver(key, name: "Beltrano de Tal", cpf: "123.456.789-09", sequence: 2)

      expect(result).to be_registered
      expect(sent).to include(%(Id="ID110114#{key}02"), "<nSeqEvento>2</nSeqEvento>")
      expect(detail(sent)).to eq("<evIncCondutorMDFe><descEvento>Inclusao Condutor</descEvento><condutor><xNome>Beltrano de Tal</xNome><CPF>12345678909</CPF></condutor></evIncCondutorMDFe>")
      expect(result.filename).to eq("#{key}_110114_02-procEventoMDFe.xml")
    end

    it "refuses a CPF with wrong check digits" do
      expect { client.add_driver(key, name: "Beltrano", cpf: "12345678900") }.to raise_error(ArgumentError, /rej. 645/)
    end
  end

  describe "#add_documents" do
    let(:nfe) { document_key(55) }

    it "adds the NF-e loaded on the way of a manifest issued to be loaded later" do
      transport.answer(:event, ret_evento_mdfe(key, type: "110115"))

      result = client.add_documents(key, protocol: protocol, load_at: ["Americana", "SP"],
        documents: [{nfe: nfe, unload_at: ["Campinas", "SP"]}, {nfe: document_key(55, number: 6), unload_at: "3548500"}])

      expect(result).to be_registered
      expect(detail(sent)).to start_with("<evIncDFeMDFe><descEvento>Inclusao DF-e</descEvento><nProt>#{protocol}</nProt><cMunCarrega>3501608</cMunCarrega><xMunCarrega>Americana</xMunCarrega>" \
        "<infDoc><cMunDescarga>3509502</cMunDescarga><xMunDescarga>Campinas</xMunDescarga><chNFe>#{nfe}</chNFe></infDoc><infDoc><cMunDescarga>3548500</cMunDescarga><xMunDescarga>Santos</xMunDescarga>")
    end

    it "takes only NF-e keys" do
      expect { client.add_documents(key, protocol: protocol, load_at: "3550308", documents: [{nfe: document_key(57), unload_at: "3548500"}]) }
        .to raise_error(ArgumentError, /not an NF-e key/)
      expect { client.add_documents(key, protocol: protocol, load_at: "3550308", documents: []) }.to raise_error(ArgumentError, "nothing to add")
    end
  end
end
