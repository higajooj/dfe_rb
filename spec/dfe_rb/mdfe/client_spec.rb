RSpec.describe DfeRb::Mdfe::Client do
  let(:transport) { FakeTransport.new }
  let(:client) { mdfe_client(transport) }
  let(:manifest) { own_cargo_manifest(client) }
  let(:signed) { client.sign(manifest) }
  let(:base) { "https://mdfe-homologacao.svrs.rs.gov.br/ws/" }

  describe "#endpoint" do
    it "resolves every service at the SVRS, whatever the issuer's state" do
      endpoint = client.endpoint(:authorization)

      expect(endpoint).to have_attributes(url: "#{base}MDFeRecepcaoSinc/MDFeRecepcaoSinc.asmx", operation: "mdfeRecepcao",
        namespace: "http://www.portalfiscal.inf.br/mdfe/wsdl/MDFeRecepcaoSinc", request_tag: "mdfeDadosMsg", answer: "retMDFe")
      expect(mdfe_client(transport, environment: :production).endpoint(:event).url)
        .to eq("https://mdfe.svrs.rs.gov.br/ws/MDFeRecepcaoEvento/MDFeRecepcaoEvento.asmx")
      expect(mdfe_client(transport, endpoints: {consult: "https://proxy.test/c"}).endpoint(:consult).url).to eq("https://proxy.test/c")
      expect { client.endpoint(:inutilization) }.to raise_error(ArgumentError, /unknown service/)
    end

    it "puts the payload in <mdfeDadosMsg>" do
      envelope = DfeRb::Transport.envelope(client.endpoint(:status).namespace, "<a/>", tag: client.endpoint(:status).request_tag)

      expect(envelope).to include(%(<soap12:Body><mdfeDadosMsg xmlns="http://www.portalfiscal.inf.br/mdfe/wsdl/MDFeStatusServico"><a/></mdfeDadosMsg></soap12:Body>))
    end
  end

  describe "#status" do
    it "asks the authorizer" do
      transport.answer(:status, ret_cons_stat_serv_mdfe)

      status = client.status

      expect(status).to be_online
      expect(status.average_seconds).to eq(1)
      expect(transport.calls.first.url).to eq("#{base}MDFeStatusServico/MDFeStatusServico.asmx")
      expect(transport.calls.first.xml).to eq(%(<consStatServMDFe xmlns="#{MdfeHelpers::MDFE_NS}" versao="3.00"><tpAmb>2</tpAmb><xServ>STATUS</xServ></consStatServMDFe>))
    end
  end

  describe "#sign" do
    it "produces a verified signed MDFe with its key and digest, the signature last" do
      expect(signed.key).to eq(manifest.key.to_s)
      expect(signed.xml).to match(%r{</infMDFeSupl><Signature xmlns="http://www.w3.org/2000/09/xmldsig#">.*</Signature></MDFe>\z}m)
      expect(DfeRb::Mdfe::Signature.verify(signed.xml)).to be(true)
      expect(DfeRb::Mdfe::Schemas.mdfe_issues(signed.xml)).to eq([])
    end

    it "is idempotent for already signed input and takes raw XML" do
      expect(client.sign(signed)).to be(signed)
      expect(client.sign(signed.xml).xml).to eq(signed.xml)
      expect(client.sign(manifest.to_xml).key).to eq(manifest.key.to_s)
    end

    it "checks raw XML as it checks a Manifest" do
      broken = manifest.to_xml.sub("<qNFe>2</qNFe>", "<qNFe>3</qNFe>")

      expect { client.sign(broken) }.to raise_error(DfeRb::ValidationError, /F51, rej. 667/)
      expect(client.sign(broken, strict: false).key).to eq(manifest.key.to_s)
    end

    it "refuses a manifest of another environment or another company" do
      production = own_cargo_manifest(mdfe_client(transport, environment: :production))
      stranger = DfeRb::Mdfe::Client.new(certificate: mdfe_certificate(cnpj: "11222333000181"), uf: "SP", transport: transport)

      expect { client.sign(production) }.to raise_error(DfeRb::ValidationError, /built for production/)
      expect { stranger.sign(manifest.to_xml) }.to raise_error(DfeRb::ValidationError, /rej. 213/)
    end

    it "signs the QR code of a manifest built in contingency" do
      contingency = client.sign(own_cargo_manifest(client, &:contingency))
      url = DfeRb::Mdfe::Document.new(contingency.xml).qr_code

      expect(DfeRb::AccessKey.parse(contingency.key).emission_type).to eq(2)
      expect(url).to include("&sign=")
      expect(url).to eq(DfeRb::Mdfe::QrCode.url(key: contingency.key, environment: :homologacao, certificate: client.certificate))
    end
  end

  describe "#authorize" do
    it "sends the signed MDFe gzipped and returns its protocol" do
      transport.answer(:authorization, ->(_payload) { ret_mdfe(prot_mdfe(signed.key)) })

      result = client.authorize(signed)

      expect(result).to be_authorized
      expect(result).to have_attributes(key: signed.key, protocol: "935260000000123", status: :authorized, recovered?: false)
      expect(DfeRb::Mdfe::Requests.unpack(transport.calls.first.xml)).to eq(signed.xml)
      expect(result.filename).to eq("#{signed.key}-procMDFe.xml")
      expect(result.proc_xml).to eq(%(<?xml version="1.0" encoding="UTF-8"?><mdfeProc xmlns="#{MdfeHelpers::MDFE_NS}" versao="3.00">#{signed.xml}#{prot_mdfe(signed.key)}</mdfeProc>))
    end

    it "builds, signs and sends a Manifest in one call" do
      transport.answer(:authorization, ->(payload) { ret_mdfe(prot_mdfe(DfeRb::Mdfe::Document.new(DfeRb::Mdfe::Requests.unpack(payload)).key)) })

      expect(client.authorize(manifest)).to be_authorized
    end

    it "returns a rejection as a result" do
      transport.answer(:authorization, ret_mdfe(code: 203, message: "Rejeicao: Emissor nao habilitado para emissao do MDF-e"))

      result = client.authorize(signed)

      expect(result).to have_attributes(status: :rejected, code: 203, protocol: nil, proc_xml: nil)
      expect { client.authorize!(signed) }.to raise_error(DfeRb::Mdfe::Rejected, /203/)
    end

    it "tells a manifest left open and a consumption block apart" do
      transport.answer(:authorization, ret_mdfe(code: 611, message: "Rejeicao: Existe MDF-e nao encerrado para esta placa"),
        ret_mdfe(code: 678, message: "Rejeicao: Consumo Indevido"))

      expect { client.authorize!(signed) }.to raise_error(DfeRb::Mdfe::Unclosed) { |error| expect(error.result).to be_unclosed }
      expect { client.authorize!(signed) }.to raise_error(DfeRb::Mdfe::ConsumptionBlocked)
    end

    it "recovers the protocol when the answer was lost" do
      transport.answer(:authorization, DfeRb::TransportError.new("Net::ReadTimeout", maybe_processed: true))
      transport.answer(:consult, ret_cons_sit_mdfe(protocol_xml: prot_mdfe(signed.key, digest: signed.digest_value)))

      result = client.authorize(signed)

      expect(result).to be_authorized
      expect(result).to be_recovered
      expect(result.proc_xml).to include(signed.xml)
    end

    it "recovers on a duplicate report, and refuses a different document under the same key" do
      transport.answer(:authorization, ret_mdfe(code: 204, message: "Rejeicao: Duplicidade de MDF-e"))
      transport.answer(:consult, ret_cons_sit_mdfe(protocol_xml: prot_mdfe(signed.key, digest: signed.digest_value)),
        ret_cons_sit_mdfe(protocol_xml: prot_mdfe(signed.key, digest: "BBBBBBBBBBBBBBBBBBBBBBBBBBB=")))

      expect(client.authorize(signed)).to be_recovered
      expect { client.authorize(signed) }.to raise_error(DfeRb::Mdfe::Conflict, /different content/)
    end

    it "reports a recovered manifest that was closed since" do
      transport.answer(:authorization, ret_mdfe(code: 204, message: "Rejeicao: Duplicidade de MDF-e"))
      transport.answer(:consult, ret_cons_sit_mdfe(code: 132, message: "Encerramento de MDF-e homologado",
        protocol_xml: prot_mdfe(signed.key, digest: signed.digest_value)))

      result = client.authorize(signed)

      expect(result).to have_attributes(status: :closed, authorized?: false, recovered?: true)
      expect(result.proc_xml).to include("<mdfeProc")
    end

    it "raises the first error when nothing can be learned, or when it certainly wasn't processed" do
      refused = DfeRb::TransportError.new("could not connect", maybe_processed: false)
      transport.answer(:authorization, DfeRb::TransportError.new("Net::ReadTimeout", maybe_processed: true), refused)
      transport.answer(:consult, DfeRb::TransportError.new("could not connect", maybe_processed: false))

      expect { client.authorize(signed) }.to raise_error(DfeRb::TransportError, "Net::ReadTimeout")
      expect { client.authorize(signed) }.to raise_error(refused)
      expect(transport.calls_to(:consult).size).to eq(1)
    end

    it "sends again a manifest SEFAZ never got" do
      transport.answer(:authorization, DfeRb::TransportError.new("Net::ReadTimeout", maybe_processed: true))
      transport.answer(:consult, ret_cons_sit_mdfe(code: 217, message: "Rejeicao: MDF-e nao consta na base de dados da SEFAZ"))

      expect { client.authorize(signed) }.to raise_error(DfeRb::TransportError)
    end
  end

  describe "#consult" do
    it "tells where the key stands, with its events" do
      event = %(<procEventoMDFe xmlns="#{MdfeHelpers::MDFE_NS}" versao="3.00"><eventoMDFe versao="3.00"><infEvento Id="ID1"><tpEvento>110114</tpEvento>) +
        %(<nSeqEvento>2</nSeqEvento><detEvento versaoEvento="3.00"><evIncCondutorMDFe><descEvento>Inclusao Condutor</descEvento></evIncCondutorMDFe></detEvento></infEvento></eventoMDFe>) +
        ret_evento_mdfe(signed.key, type: "110114", sequence: 2) + "</procEventoMDFe>"
      transport.answer(:consult, ret_cons_sit_mdfe(protocol_xml: prot_mdfe(signed.key), events: [event]))

      result = client.consult(signed.key)

      expect(result).to have_attributes(status: :authorized, found?: true, protocol: "935260000000123")
      expect(result.events.map { |e| [e.type, e.sequence, e.code, e.protocol, e.description] })
        .to eq([["110114", 2, 135, "935260000000999", "Inclusao Condutor"]])
      expect(transport.calls.first.xml).to eq(%(<consSitMDFe xmlns="#{MdfeHelpers::MDFE_NS}" versao="3.00"><tpAmb>2</tpAmb><xServ>CONSULTAR</xServ><chMDFe>#{signed.key}</chMDFe></consSitMDFe>))
    end

    it "knows a key SEFAZ doesn't hold, and refuses one that isn't a key" do
      transport.answer(:consult, ret_cons_sit_mdfe(code: 217, message: "Rejeicao: MDF-e nao consta na base de dados da SEFAZ"))

      expect(client.consult(signed.key)).to have_attributes(status: :not_found, found?: false)
      expect { client.consult("123") }.to raise_error(ArgumentError, /invalid access key/)
    end
  end

  describe "#unclosed" do
    it "lists the issuer's manifests still open" do
      transport.answer(:unclosed, ret_cons_mdfe_nao_enc([[signed.key, "935260000000123"]]))

      result = client.unclosed

      expect(result).to be_any
      expect(result.manifests).to eq([DfeRb::Mdfe::UnclosedManifest.new(key: signed.key, protocol: "935260000000123")])
      expect(transport.calls.first.xml).to eq(%(<consMDFeNaoEnc xmlns="#{MdfeHelpers::MDFE_NS}" versao="3.00"><tpAmb>2</tpAmb>) +
        %(<xServ>CONSULTAR NÃO ENCERRADOS</xServ><CNPJ>#{MdfeHelpers::ISSUER}</CNPJ></consMDFeNaoEnc>))
      expect(DfeRb::Xsd.issues(transport.calls.first.xml, package: "mdfe_3.00", file: "consMDFeNaoEnc_v3.00.xsd")).to eq([])
    end

    it "says when there is none" do
      transport.answer(:unclosed, ret_cons_mdfe_nao_enc)

      expect(client.unclosed).to be_none
    end
  end

  it "validates the plain requests against their schemas" do
    {
      "consStatServMDFe_v3.00.xsd" => DfeRb::Mdfe::Requests.status(environment: :homologacao),
      "consSitMDFe_v3.00.xsd" => DfeRb::Mdfe::Requests.consult(key: signed.key, environment: :homologacao)
    }.each { |file, xml| expect(DfeRb::Xsd.issues(xml, package: "mdfe_3.00", file: file)).to eq([]) }
  end
end
