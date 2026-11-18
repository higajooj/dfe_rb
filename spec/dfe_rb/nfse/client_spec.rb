RSpec.describe DfeRb::Nfse::Client do
  let(:transport) { NfseHelpers::FakeRest.new }
  let(:client) { nfse_client(transport) }
  let(:declaration) { service_declaration(client) }
  let(:signed) { client.sign(declaration) }
  let(:sefin) { "https://sefin.producaorestrita.nfse.gov.br/SefinNacional" }
  let(:adn) { "https://adn.producaorestrita.nfse.gov.br" }

  def unpacked(call, field) = DfeRb::Nfse::Requests.unpack(call.body.fetch(field))

  describe "#url" do
    it "addresses the Sefin Nacional and the ADN of each environment, or the hosts given" do
      expect(client.url(:issue)).to eq("#{sefin}/nfse")
      expect(client.url(:distribution, nsu: 10)).to eq("#{adn}/contribuintes/DFe/10")
      expect(nfse_client(transport, environment: :production).url(:consult, key: nfse_key)).to eq("https://sefin.nfse.gov.br/SefinNacional/nfse/#{nfse_key}")
      expect(nfse_client(transport, endpoints: {sefin: "https://proxy.test/sefin/"}).url(:dps, id: "DPS1")).to eq("https://proxy.test/sefin/dps/DPS1")
      expect { client.url(:inutilization) }.to raise_error(ArgumentError, /unknown service/)
    end

    it "builds for the environment's layout, or the one given" do
      expect(client.layout.name).to eq(:nt009)
      expect(nfse_client(transport, environment: :production).layout.name).to eq(:v1_01)
      expect(nfse_client(transport, environment: :production, layout: :nt009).build_declaration.layout.name).to eq(:nt009)
    end
  end

  describe "#sign" do
    it "signs the DPS in RSA-SHA256 and keeps its Id and digest" do
      expect(signed.id).to eq(declaration.id)
      expect(signed.xml).to match(%r{</infDPS><Signature xmlns="http://www.w3.org/2000/09/xmldsig#">.*</Signature></DPS>\z}m)
      expect(signed.xml).to include("xmldsig-more#rsa-sha256", "xmlenc#sha256")
      expect(DfeRb::Nfse::Signature.verify(signed.xml)).to be(true)
      expect(client.layout.dps_issues(signed.xml)).to eq([])
    end

    it "is idempotent for signed input and checks raw XML like a declaration" do
      expect(client.sign(signed)).to be(signed)
      expect(client.sign(signed.xml).xml).to eq(signed.xml)
      expect(client.sign(declaration.to_xml).digest_value).to eq(signed.digest_value)

      bad = declaration.to_xml.sub("<tpRetISSQN>1</tpRetISSQN>", "<tpRetISSQN>1</tpRetISSQN><pAliq>6.00</pAliq>")
      expect { client.sign(bad) }.to raise_error(DfeRb::ValidationError, /E0595/)
      expect(client.sign(bad, strict: false).xml).to include("<pAliq>6.00</pAliq>")
    end

    it "checks every input against the client's layout" do
      other_layout = service_declaration(layout: :v1_01)
      broken = DfeRb::Nfse::SignedDeclaration.new(xml: signed.xml.sub("<nDPS>1</nDPS>", "<nDPS>0</nDPS>"), id: signed.id, digest_value: signed.digest_value)

      expect { client.sign(other_layout) }.to raise_error(DfeRb::ValidationError, /built for the layout v1_01, but this client sends nt009/)
      expect { client.sign(broken) }.to raise_error(DfeRb::ValidationError, /nDPS/)
    end

    it "refuses a DPS signed elsewhere with a certificate of someone else than its issuer (E0718)" do
      taker = DfeRb::Certificate.from_pkcs12(pkcs12_der(cnpj: NfseHelpers::TAKER), "cert-pass")
      foreign = DfeRb::Nfse::Signature.sign_dps(declaration.to_xml, taker)

      expect { client.sign(foreign) }.to raise_error(DfeRb::ValidationError, /the DPS's signature belongs to CNPJ root 11222333.*E0718/)
    end

    it "refuses another environment and another issuer's certificate" do
      production = service_declaration(environment: :production, layout: :nt009)
      stranger = nfse_client(transport).tap { |c| c.instance_variable_set(:@certificate, nfse_certificate(cnpj: "11222333000181")) }

      expect { client.sign(production) }.to raise_error(DfeRb::ValidationError, /built for production.*E0006/)
      expect { stranger.sign(declaration) }.to raise_error(DfeRb::ValidationError, /CNPJ root 11222333.*E0718/)
    end
  end

  describe "#issue" do
    it "sends the signed DPS in GZip and Base64 and returns the NFS-e" do
      transport.answer(:issue, issued_answer(signed.xml))

      result = client.issue(signed)

      call = transport.calls_to(:issue).first
      expect(call.method).to eq(:post)
      expect(unpacked(call, "dpsXmlGZipB64")).to eq(%(<?xml version="1.0" encoding="UTF-8"?>#{signed.xml}))
      expect(result).to be_issued
      expect(result).to have_attributes(id: signed.id, key: nfse_key, http_status: 201, signed_xml: signed.xml, recovered?: false)
      expect(result.alerts.map(&:code)).to eq(["A0001"])
      expect(result.note).to have_attributes(key: nfse_key, number: "1", status_code: 100, iss_amount: "20.00", dps_id: signed.id)
      expect(result.note.consult_url).to eq("https://www.nfse.gov.br/ConsultaPublica/?tpc=1&chave=#{nfse_key}")
      expect(result.filename).to eq("#{nfse_key}-nfse.xml")
    end

    it "returns a rejection as a result, and raises it with issue!" do
      transport.answer(:issue, rejected_answer("E0312", "Servico nao administrado"))

      result = client.issue(signed)

      expect(result).to be_rejected
      expect(result).to have_attributes(code: "E0312", message: "Servico nao administrado", http_status: 400, nfse_xml: nil)
      expect { client.issue!(signed) }.to raise_error(DfeRb::Nfse::Rejected, "E0312 Servico nao administrado")
    end

    it "looks the DPS up when the answer is lost, and returns the note holding it" do
      transport.answer(:issue, DfeRb::TransportError.new("Net::ReadTimeout", maybe_processed: true))
      transport.answer(:dps, [200, {"idDps" => signed.id, "chaveAcesso" => nfse_key}])
      transport.answer(:consult, [200, {"chaveAcesso" => nfse_key, "nfseXmlGZipB64" => gzip64(nfse_xml(signed.xml))}])

      result = client.issue(signed)

      expect(result).to be_issued
      expect(result).to be_recovered
      expect(result.key).to eq(nfse_key)
      expect(transport.calls_to(:dps).first.url).to eq("#{sefin}/dps/#{signed.id}")
    end

    it "looks the DPS up when a success comes without the NFS-e, or with one it can't read" do
      transport.answer(:issue, [201, {"chaveAcesso" => nfse_key}], [201, {"chaveAcesso" => nfse_key, "nfseXmlGZipB64" => "bm90IGd6aXA="}])
      transport.answer(:dps, [200, {"idDps" => signed.id, "chaveAcesso" => nfse_key}])
      transport.answer(:consult, [200, {"chaveAcesso" => nfse_key, "nfseXmlGZipB64" => gzip64(nfse_xml(signed.xml))}])

      expect(client.issue(signed)).to be_recovered
      expect(client.issue(signed)).to be_recovered
    end

    it "refuses a note whose DPS has another Id, even with the same digest text" do
      forged = nfse_xml(signed.xml).sub(%(Id="#{signed.id}"), %(Id="#{signed.id.sub(/1\z/, "2")}"))
      transport.answer(:issue, [201, {"chaveAcesso" => nfse_key, "nfseXmlGZipB64" => gzip64(forged)}])

      expect { client.issue(signed, recover: false) }.to raise_error(DfeRb::Nfse::Conflict, /is of DPS.*2, not of/)
    end

    it "keeps E0014 in the error when the lookup fails" do
      transport.answer(:issue, rejected_answer("E0014", "Serie e numero ja usados"))
      transport.answer(:dps, error_answer(503, "E9999", "Indisponivel"))

      expect { client.issue(signed) }.to raise_error(DfeRb::TransportError, /HTTP 503.*after E0014 Serie e numero ja usados/)
    end

    it "recovers a series and number already used by this same DPS (E0014)" do
      transport.answer(:issue, rejected_answer("E0014"))
      transport.answer(:dps, [200, {"idDps" => signed.id, "chaveAcesso" => nfse_key}])
      transport.answer(:consult, [200, {"chaveAcesso" => nfse_key, "nfseXmlGZipB64" => gzip64(nfse_xml(signed.xml))}])

      expect(client.issue(signed)).to be_recovered
    end

    it "raises Conflict when the note found carries another DPS, and the first error when nothing is found" do
      other = client.sign(service_declaration(client) { |d| d.amount "999.00" })
      transport.answer(:issue, rejected_answer("E0014"))
      transport.answer(:dps, [200, {"idDps" => signed.id, "chaveAcesso" => nfse_key}])
      transport.answer(:consult, [200, {"chaveAcesso" => nfse_key, "nfseXmlGZipB64" => gzip64(nfse_xml(other.xml))}])

      expect { client.issue(signed) }.to raise_error(DfeRb::Nfse::Conflict, /not this DPS/)

      lost = NfseHelpers::FakeRest.new
      lost.answer(:issue, error_answer(500, "E9999", "Falha"))
      lost.answer(:dps, error_answer(404, "E2404", "Não foi gerada"))
      expect { nfse_client(lost).issue(signed) }.to raise_error(DfeRb::TransportError, /HTTP 500.*E9999 Falha/)
    end
  end

  describe "lookups" do
    it "consults a note by its key" do
      transport.answer(:consult, [200, {"chaveAcesso" => nfse_key, "nfseXmlGZipB64" => gzip64(nfse_xml(signed.xml))}], error_answer(404, "E2401", "Chave de acesso não encontrada."))

      expect(client.consult(nfse_key)).to have_attributes(found?: true, status: :found)
      expect(client.consult(nfse_key)).to have_attributes(status: :not_found, message: "Chave de acesso não encontrada.")
      expect { client.consult("123") }.to raise_error(ArgumentError, /50 characters/)
    end

    it "finds the key of a DPS's note, and whether there is one" do
      transport.answer(:dps, [200, {"idDps" => signed.id, "chaveAcesso" => nfse_key}])

      expect(client.find(signed)).to have_attributes(found?: true, key: nfse_key)
      expect(client.issued?(signed.id)).to be(true)

      missing = NfseHelpers::FakeRest.new.answer(:dps, [404, nil])
      expect(nfse_client(missing).issued?(signed)).to be(false)
      expect { client.find("DPS1") }.to raise_error(ArgumentError, /42 characters/)
    end
  end

  describe "events" do
    let(:event_answer) { [201, {"tipoAmbiente" => 2, "eventoXmlGZipB64" => gzip64("<evento/>")}] }

    it "cancels a note with a signed request the schema takes" do
      transport.answer(:event, event_answer)

      result = client.cancel(nfse_key, reason: "Servico nao prestado por desistencia", code: :not_rendered)

      call = transport.calls_to(:event).first
      request = unpacked(call, "pedidoRegistroEventoXmlGZipB64")
      document = Nokogiri::XML(request).tap(&:remove_namespaces!)
      expect(call.url).to eq("#{sefin}/nfse/#{nfse_key}/eventos")
      expect(document.at_xpath("//infPedReg/@Id").value).to eq("PRE#{nfse_key}101101")
      expect(document.at_xpath("//CNPJAutor").text).to eq(NfseHelpers::PROVIDER)
      expect(document.at_xpath("//e101101/xDesc").text).to eq("Cancelamento de NFS-e")
      expect(document.at_xpath("//e101101/cMotivo").text).to eq("2")
      expect(document.at_xpath("//dhEvento").text).to end_with("-04:00")
      expect(DfeRb::Nfse::Signature.verify(result.request_xml)).to be(true)
      expect(client.layout.event_issues(result.request_xml)).to eq([])
      expect(result).to have_attributes(registered?: true, type: "101101", event_xml: "<evento/>", filename: "#{nfse_key}_101101-evento.xml")
    end

    it "returns the Sefin's refusal of an event" do
      transport.answer(:event, error_answer(400, "E1831", "A NFS-e indicada não existe"))

      result = client.cancel(nfse_key, reason: "Erro na emissao da nota fiscal")

      expect(result).to have_attributes(registered?: false, code: "E1831", message: "A NFS-e indicada não existe")
    end

    it "confirms, rejects and asks for a cancellation review" do
      transport.answer(:event, event_answer)

      client.confirm(nfse_key, as: :taker)
      client.reject(nfse_key, as: :intermediary, code: :values, reason: "Valor do servico diverge do contratado")
      client.request_cancellation(nfse_key, reason: "Prazo de cancelamento expirado", code: :other)

      requests = transport.calls_to(:event).map { |call| unpacked(call, "pedidoRegistroEventoXmlGZipB64") }
      details = requests.map { |xml| Nokogiri::XML(xml).tap(&:remove_namespaces!).at_xpath("//infPedReg/*[last()]") }
      expect(details.map(&:name)).to eq(%w[e203202 e204207 e101103])
      expect(details[0].element_children.map(&:text)).to eq(["Manifestação de NFS-e - Confirmação do Tomador"])
      expect(details[1].element_children.map(&:text)).to eq(["Manifestação de NFS-e - Rejeição do Intermediário", "5", "Valor do servico diverge do contratado"])
      expect(details[2].at_xpath("cMotivo").text).to eq("9")
      requests.each { |xml| expect(client.layout.event_issues(xml)).to eq([]) }
      expect { client.reject(nfse_key) }.to raise_error(ArgumentError, /E1949/)
      expect { client.reject(nfse_key, as: :provider) }.to raise_error(ArgumentError, /E1944/)
      expect { client.cancel(nfse_key, reason: "curto") }.to raise_error(ArgumentError, /15 to 255/)
      expect { client.confirm(nfse_key, as: :issuer) }.to raise_error(ArgumentError, /as: takes/)
    end

    it "reads an event back from the Sefin, and every event of a note from the ADN" do
      transport.answer(:event_query, [200, {"eventoXmlGZipB64" => gzip64("<evento/>")}])
      transport.answer(:events, [200, {"StatusProcessamento" => "DOCUMENTOS_LOCALIZADOS",
                                       "LoteDFe" => [{"NSU" => 7, "ChaveAcesso" => nfse_key, "TipoDocumento" => "EVENTO", "TipoEvento" => "CANCELAMENTO", "ArquivoXml" => gzip64("<evento/>")}]}])

      expect(client.event(nfse_key, type: 101101).event_xml).to eq("<evento/>")
      expect(transport.calls_to(:event_query).first.url).to eq("#{sefin}/nfse/#{nfse_key}/eventos/101101/1")
      expect(client.events(nfse_key).documents.first).to have_attributes(event?: true, event_type: "CANCELAMENTO", xml: "<evento/>",
        filename: "#{nfse_key}_cancelamento_7-evento.xml")
    end
  end

  describe "#distribute" do
    it "names the certificate's CNPJ and decodes the documents" do
      transport.answer(:distribution, [200, {"TipoConsulta" => "CnpjBase", "StatusProcessamento" => "DOCUMENTOS_LOCALIZADOS",
                                             "LoteDFe" => [{"NSU" => 11, "ChaveAcesso" => nfse_key, "TipoDocumento" => "NFSE", "ArquivoXml" => gzip64("<NFSe/>")},
                                               {"NSU" => 12, "ChaveAcesso" => nfse_key, "TipoDocumento" => "EVENTO", "TipoEvento" => "CANCELAMENTO", "ArquivoXml" => gzip64("<evento/>")}],
                                             "Alertas" => [], "Erros" => []}])

      batch = client.distribute(after: 10)

      expect(transport.calls_to(:distribution).first.url).to eq("#{adn}/contribuintes/DFe/10?lote=true&cnpjConsulta=#{NfseHelpers::PROVIDER}")
      expect(batch).to have_attributes(found?: true, empty?: false, last_nsu: 12, query: "CnpjBase")
      expect(batch.documents.map(&:kind)).to eq(%i[nfse event])
      expect(batch.documents.first).to have_attributes(xml: "<NFSe/>", filename: "#{nfse_key}-nfse.xml")
    end

    it "says when it caught up, and takes another taxpayer" do
      transport.answer(:distribution, [404, {"StatusProcessamento" => "NENHUM_DOCUMENTO_LOCALIZADO", "LoteDFe" => [],
                                             "Erros" => [{"Codigo" => "E2220", "Descricao" => "Nenhum documento localizado"}]}])

      batch = client.distribute(after: 12, cpf: "529.982.247-25", batch: false)

      expect(batch).to have_attributes(caught_up?: true, empty?: true, last_nsu: nil, found?: false, rejected?: false)
      expect(batch.errors.first.code).to eq("E2220")
      expect(transport.calls_to(:distribution).first.url).to end_with("/DFe/12?lote=false&cpfConsulta=52998224725")
      expect { client.distribute(cnpj: "1", cpf: "2") }.to raise_error(ArgumentError, /E2244/)
    end
  end

  describe "municipal parameters" do
    it "reads a municipality's agreement and its ISSQN rates for a service" do
      transport.answer(:agreement, [200, {"parametrosConvenio" => {"aderenteAmbienteNacional" => 1, "aderenteEmissorNacional" => 1}, "mensagem" => "ok"}])
      transport.answer(:rates, [200, {"aliquotas" => {"01.01.01.000" => [{"Incidencia" => "SIM", "Aliq" => 2.0, "DtIni" => "2025-12-19T00:00:00", "DtFim" => nil}]}}])

      expect(client.agreement).to have_attributes(found?: true, national_issuer?: true, national_data?: true, city: NfseHelpers::CITY)
      rates = client.rates(["Goiania", "GO"], service: "01.01.01", on: Date.new(2026, 11, 18))

      expect(transport.calls_to(:rates).first.url).to eq("#{adn}/parametrizacao/5208707/01.01.01.000/2026-11-18/aliquota")
      expect(rates).to have_attributes(found?: true, rate: BigDecimal(2))
      expect(rates.rates.first).to have_attributes(taxed?: true, starts_on: Date.new(2025, 12, 19), ends_on: nil)
      expect { client.rates(service: "0101") }.to raise_error(ArgumentError, /6-digit/)
    end
  end
end
