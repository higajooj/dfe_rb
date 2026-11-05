RSpec.describe DfeRb::Nfce::Client do
  let(:transport) { FakeTransport.new }
  let(:client) { nfce_client(transport) }

  def authorized_answer = ->(xml) { ret_env_nfe_sync(prot_nfe(xml[/Id="NFe(\d{44})"/, 1])) }

  it "asks the state's NFC-e authorizer about its status, and has no SVC to ask" do
    transport.answer(:status, ret_cons_stat_serv)

    expect(client.status).to be_online
    expect(transport.calls.last.url).to eq("https://hom.nfce.sefaz.ms.gov.br/ws/NFeStatusServico4")
    expect { client.status(contingency: true) }.to raise_error(DfeRb::Nfce::Unsupported, /SVC doesn't authorize NFC-e \(rej. 783\).*contingency :offline/)
  end

  it "signs an NFC-e with its QR code ahead of the signature" do
    signed = client.sign(nfce_invoice(client))

    expect(signed.xml).to match(%r{</infNFe><infNFeSupl><qrCode>[^<]+\|3\|2</qrCode><urlChave>[^<]+</urlChave></infNFeSupl><Signature})
    expect(DfeRb::Nfe::Signature.verify(signed.xml)).to be(true)
    expect(DfeRb::Nfce::AccessKey.parse(signed.key).model).to eq(65)
  end

  it "authorizes one note synchronously at the NFC-e authorizer and archives it with its QR code" do
    transport.answer(:authorization, authorized_answer)
    result = client.authorize(client.sign(nfce_invoice(client)))

    expect(result).to be_authorized
    expect(transport.calls.last.url).to eq("https://hom.nfce.sefaz.ms.gov.br/ws/NFeAutorizacao4")
    expect(transport.calls.last.xml).to include("<indSinc>1</indSinc>")
    expect(result.proc_xml).to include("<nfeProc", "<infNFeSupl>", "<protNFe")
    expect(result.qr_code).to eq("http://www.dfe.ms.gov.br/nfce/qrcode?p=#{result.key}|3|2")
    expect(result.consult_url).to eq("www.dfe.ms.gov.br/nfce/consulta")
  end

  it "sends a single note per lot (rej. 126)" do
    notes = [nfce_invoice(client, number: 1), nfce_invoice(client, number: 2)]

    expect { client.authorize(notes) }.to raise_error(ArgumentError, /single note \(rej. 126\)/)
    expect(transport.calls).to be_empty
  end

  it "adds the QR code to an unsigned NFC-e handed in as XML, and refuses a signed one without it" do
    xml = nfce_invoice(client).to_xml.sub(%r{<infNFeSupl>.*</infNFeSupl>}, "")
    signed = client.sign(xml)

    expect(signed.xml).to include("<infNFeSupl><qrCode>http://www.dfe.ms.gov.br/nfce/qrcode?p=#{signed.key}|3|2</qrCode>")
    bare = DfeRb::Nfe::Signature.sign_nfe(xml, nfe_certificate)
    expect { client.sign(bare) }.to raise_error(DfeRb::ValidationError, /a signed NFC-e carries its QR code \(rej. 394\)/)
  end

  it "holds an NFC-e handed in as XML to the rules of modelo 65" do
    xml = nfce_invoice(client).to_xml.sub("<modFrete>9</modFrete>", "<modFrete>0</modFrete>")

    expect { client.sign(xml) }.to raise_error(DfeRb::ValidationError, /freight only on a home delivery.*\(rej. 753\)/)
  end

  it "sends each model to its own client" do
    nfe = DfeRb::Nfe::Client.new(certificate: nfe_certificate, uf: "MS", transport: transport)

    expect { nfe.sign(nfce_invoice(client)) }.to raise_error(DfeRb::ValidationError, /NFC-e \(modelo 65\): issue it with DfeRb::Nfce::Client/)
    expect { client.sign(simples_invoice(nfe_client(transport))) }.to raise_error(DfeRb::ValidationError, /Nfce::Client issues modelo 65/)
  end

  it "signs an off-line note's QR code with the client's certificate" do
    invoice = nfce_invoice(client) { |nfce| nfce.contingency :offline, since: Time.now - 60, reason: "Sem comunicacao com a SEFAZ" }
    parsed = DfeRb::Nfce::QrCode.parse(client.sign(invoice).xml[%r{<qrCode>([^<]+)</qrCode>}, 1])

    expect(parsed[:parameters].size).to eq(8)
    expect(DfeRb::Nfce::QrCode.signed_by?(parsed[:signed_content], parsed[:signature], nfe_certificate.certificate)).to be(true)
  end

  it "cancels at the state's NFC-e authorizer" do
    key = client.sign(nfce_invoice(client)).key
    transport.answer(:event, ret_env_evento(key, type: "110111"))
    result = client.cancel(key, protocol: "150260000000123", reason: "Venda desfeita pelo consumidor")

    expect(result).to be_registered
    expect(transport.calls.last.url).to eq("https://hom.nfce.sefaz.ms.gov.br/ws/NFeRecepcaoEvento4")
  end

  describe "cancellation by substitution" do
    let(:original) { client.sign(nfce_invoice(client, number: 20)).key }
    let(:replacement) do
      client.sign(nfce_invoice(client, number: 21) { |nfce| nfce.contingency :offline, since: Time.now - 60, reason: "Sem comunicacao com a SEFAZ" }).key
    end

    it "registers evento 110112 naming the off-line note that replaced it" do
      transport.answer(:event, ret_env_evento(original, type: "110112"))
      result = client.cancel_by_substitution(original, protocol: "150260000000123", replacement: replacement,
        reason: "Emitida em contingencia para a mesma venda")
      sent = transport.calls.last.xml

      expect(result).to be_registered
      expect(sent).to include(%(Id="ID110112#{original}01"), "<cOrgao>50</cOrgao>", "<tpEvento>110112</tpEvento>")
      expect(sent).to match(%r{<detEvento versao="1.00"><descEvento>Cancelamento por substituicao</descEvento><cOrgaoAutor>50</cOrgaoAutor><tpAutor>1</tpAutor><verAplic>dfe_rb [^<]+</verAplic><nProt>150260000000123</nProt><xJust>Emitida em contingencia para a mesma venda</xJust><chNFeRef>#{replacement}</chNFeRef></detEvento>})
      expect(DfeRb::Nfe::Signature.verify(sent[%r{<evento.*</evento>}])).to be(true)
    end

    it "refuses a pair the rule rejects, before sending" do
      expect { client.cancel_by_substitution(replacement, protocol: "150260000000123", replacement: original, reason: "Emitida em contingencia") }
        .to raise_error(ArgumentError, /only a note issued normally \(tpEmis 1\).*the replacement is the note issued off-line/)
      expect(transport.calls).to be_empty
    end
  end

  it "takes no carta de correção and no EPEC" do
    expect { client.correct("5" * 44, text: "Corrigir o endereco") }.to raise_error(DfeRb::Nfce::Unsupported, /rej. 784/)
    expect { client.epec(nfce_invoice(client)) }.to raise_error(DfeRb::Nfce::Unsupported, /contingency :offline/)
  end

  it "inutilizes modelo 65 numbers" do
    transport.answer(:inutilization, ret_inut_nfe)
    client.inutilize(series: 1, from: 10, to: 12, reason: "Numeracao pulada por erro")

    expect(transport.calls.last.xml).to include("<mod>65</mod>")
    expect(transport.calls.last.url).to eq("https://hom.nfce.sefaz.ms.gov.br/ws/NFeInutilizacao4")
  end
end
