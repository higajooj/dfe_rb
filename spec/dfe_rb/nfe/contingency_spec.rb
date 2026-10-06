RSpec.describe "NF-e in contingency" do
  let(:transport) { NfeHelpers::FakeTransport.new }
  let(:client) { nfe_client(transport) }
  let(:since) { (Time.now - 3600).getlocal("-03:00") }
  let(:reason) { "SEFAZ de origem fora do ar" }

  def text(xml, tag) = Nokogiri::XML(xml).remove_namespaces!.at_xpath("//#{tag}")&.text

  describe "the states' SVC" do
    it "follows the Portal Nacional's list" do
      expect(%w[SP MG RJ RS CE].map { |uf| DfeRb::Nfe::States.contingency(uf) }.uniq).to eq(["SVC-AN"])
      expect(%w[MS PR BA MA AM].map { |uf| DfeRb::Nfe::States.contingency(uf) }.uniq).to eq(["SVC-RS"])
      expect(DfeRb::Nfe::States.contingency_emission_type("SP")).to eq(6)
      expect(DfeRb::Nfe::States.contingency_emission_type("MS")).to eq(7)
    end

    it "has every service but inutilização, in both environments" do
      url = ->(uf, env, service) { DfeRb::Nfe::Endpoints.resolve(uf: uf, environment: env, service: service, contingency: true).url }

      expect(url["SP", :production, :authorization]).to eq("https://www.sefazvirtual.fazenda.gov.br/NFeAutorizacao4/NFeAutorizacao4.asmx")
      expect(url["SP", :homologacao, :status]).to eq("https://hom.sefazvirtual.fazenda.gov.br/NFeStatusServico4/NFeStatusServico4.asmx")
      expect(url["MS", :production, :consult]).to eq("https://nfe.svrs.rs.gov.br/ws/NfeConsulta/NfeConsulta4.asmx")
      expect(url["MS", :homologacao, :event]).to eq("https://nfe-homologacao.svrs.rs.gov.br/ws/recepcaoevento/recepcaoevento4.asmx")
      expect { url["SP", :production, :inutilization] }.to raise_error(ArgumentError, /SVC has no inutilization/)
    end

    it "takes its own URL overrides" do
      endpoint = DfeRb::Nfe::Endpoints.resolve(uf: "SP", environment: :production, service: :status, contingency: true,
        overrides: {status: "https://home", contingency: {status: "https://svc"}})

      expect(endpoint.url).to eq("https://svc")
      expect(endpoint.authorizer).to eq("SVC-AN")
    end
  end

  describe "building the note" do
    it "derives tpEmis from the issuer's state and carries since when and why" do
      invoice = simples_invoice(client) { |nfe| nfe.contingency :svc, since: since, reason: reason }
      xml = invoice.to_xml

      expect(text(xml, "tpEmis")).to eq("6")
      expect(text(xml, "dhCont")).to eq(since.strftime("%Y-%m-%dT%H:%M:%S-03:00"))
      expect(text(xml, "xJust")).to eq(reason)
      expect(invoice.key.emission_type).to eq(6)
    end

    it "takes the hash form and the EPEC" do
      invoice = simples_invoice(client) { |nfe| nfe.__assign(contingency: {kind: :epec, since: since, reason: reason}) }

      expect(text(invoice.to_xml, "tpEmis")).to eq("4")
    end

    it "refuses what it doesn't know" do
      expect { simples_invoice(client) { |nfe| nfe.contingency :paper } }.to raise_error(ArgumentError, /unknown contingency :paper/)
      expect { simples_invoice(client) { |nfe| nfe.contingency :svc, from: since } }.to raise_error(ArgumentError, /since: and reason:/)
    end
  end

  describe "the rules (B22, B28)" do
    def issues(ide, state: "SP")
      tree = {"ide" => {"dhEmi" => "2026-09-29T10:00:00-03:00"}.merge(ide), "emit" => {"enderEmit" => {"UF" => state, "cMun" => "3550308"}}}
      DfeRb::Nfe::Validator.new(tree).issues.grep(%r{\Aide/(tpEmis|dhCont|xJust)})
    end

    it "keeps since when and why out of a normal note" do
      expect(issues({"tpEmis" => "1"})).to eq([])
      expect(issues({"tpEmis" => "1", "xJust" => reason})).to include(/rej. 556/)
    end

    it "requires them in contingency, the reason with 15 to 256 characters" do
      expect(issues({"tpEmis" => "6"})).to include(/rej. 557/)
      expect(issues({"tpEmis" => "6", "dhCont" => "2026-09-29T09:00:00-03:00", "xJust" => "curto"})).to include(/15 to 256 characters/)
      expect(issues({"tpEmis" => "6", "dhCont" => "2026-09-29T09:00:00-03:00", "xJust" => reason})).to eq([])
    end

    it "refuses a contingency that starts after the note" do
      expect(issues({"tpEmis" => "6", "dhCont" => "2026-09-29T10:00:01-03:00", "xJust" => reason})).to include(/can't start after/)
    end

    it "requires the state's own SVC" do
      expect(issues({"tpEmis" => "7", "dhCont" => "2026-09-29T09:00:00-03:00", "xJust" => reason})).to include(/SP is served by the SVC-AN, tpEmis 6 \(rej. 713\)/)
      expect(issues({"tpEmis" => "7", "dhCont" => "2026-09-29T09:00:00-03:00", "xJust" => reason}, state: "MS")).to eq([])
    end

    it "keeps off-line contingency to the DANFE Simplificado Tipo 2" do
      expect(issues({"tpEmis" => "9", "dhCont" => "2026-09-29T09:00:00-03:00", "xJust" => reason})).to include(/rej. 711/)
      expect(issues({"tpEmis" => "9", "tpImp" => "6", "dhCont" => "2026-09-29T09:00:00-03:00", "xJust" => reason})).to eq([])
    end
  end

  describe "routing" do
    let(:signed) { client.sign(simples_invoice(client) { |nfe| nfe.contingency :svc, since: since, reason: reason }) }
    let(:svc) { "https://hom.sefazvirtual.fazenda.gov.br" }
    let(:home) { "https://homologacao.nfe.fazenda.sp.gov.br" }

    it "asks the SVC whether it is active" do
      transport.answer(:status, ret_cons_stat_serv, ret_cons_stat_serv(code: 114, message: "SVC desabilitada pela SEFAZ Origem"),
        ret_cons_stat_serv(code: 113, message: "SVC em processo de desativacao"))

      expect(client.status(contingency: true)).to be_online
      expect(client.status(contingency: true)).to be_disabled.and(satisfy { |status| !status.online? })
      expect(client.status(contingency: true)).to be_deactivating
      expect(transport.calls.map(&:url).uniq).to eq(["#{svc}/NFeStatusServico4/NFeStatusServico4.asmx"])
    end

    it "sends a note issued for the SVC to the SVC, and asks it about the note afterwards" do
      transport.answer(:authorization, ret_env_nfe_sync(prot_nfe(signed.key)))
      transport.answer(:consult, ret_cons_sit_nfe(signed.key, protocol_xml: prot_nfe(signed.key)))
      transport.answer(:event, ret_env_evento(signed.key, type: "110111"))

      expect(client.authorize(signed)).to be_authorized
      client.consult(signed.key)
      client.cancel(signed.key, protocol: "135260000000123", reason: "Erro na digitacao dos dados")

      expect(transport.calls.map(&:url)).to eq(["#{svc}/NFeAutorizacao4/NFeAutorizacao4.asmx",
        "#{svc}/NFeConsultaProtocolo4/NFeConsultaProtocolo4.asmx", "#{svc}/NFeRecepcaoEvento4/NFeRecepcaoEvento4.asmx"])
    end

    it "recovers a lost SVC answer at the SVC" do
      transport.answer(:authorization, DfeRb::TransportError.new("ReadTimeout", maybe_processed: true))
      transport.answer(:consult, ret_cons_sit_nfe(signed.key, protocol_xml: prot_nfe(signed.key, digest: signed.digest_value)))

      result = client.authorize(signed)

      expect(result).to be_recovered.and(be_authorized)
      expect(transport.calls_to(:consult).first.url).to start_with(svc)
    end

    it "registers a carta de correção at the state's own authorizer, and anything where `via` says" do
      transport.answer(:event, ret_env_evento(signed.key, type: "110110"))
      transport.answer(:consult, ret_cons_sit_nfe(signed.key, code: 217, message: "NF-e nao consta na base de dados da SEFAZ"))

      client.correct(signed.key, text: "Corrigir o endereco de entrega")
      client.cancel(signed.key, protocol: "135260000000123", reason: "Erro na digitacao dos dados", via: :home)
      client.consult(signed.key, via: :home)

      expect(transport.calls.map(&:url)).to all(start_with(home))
      expect { client.consult(signed.key, via: :other) }.to raise_error(ArgumentError, /via must be/)
    end

    it "keeps normal notes at the state's authorizer" do
      normal = client.sign(simples_invoice(client))
      transport.answer(:authorization, ret_env_nfe_sync(prot_nfe(normal.key)))

      client.authorize(normal)

      expect(transport.calls.first.url).to start_with(home)
    end

    it "refuses a lot that mixes both" do
      normal = client.sign(simples_invoice(client, number: 2))

      expect { client.authorize([signed, normal]) }.to raise_error(ArgumentError, /can't mix/)
      expect(transport.calls).to be_empty
    end
  end

  describe "EPEC" do
    let(:signed) { client.sign(simples_invoice(client) { |nfe| nfe.contingency :epec, since: since, reason: reason }) }

    def ret_epec(key, code: 136, message: "Evento registrado, mas nao vinculado a NF-e")
      ret_env_evento(key, type: "110140", code: code, message: message, protocol: "891260000000001")
    end

    it "registers the note's summary at the Ambiente Nacional" do
      transport.answer(:manifestation, ret_epec(signed.key))

      result = client.epec(signed)

      expect(result).to be_registered
      expect(result.protocol).to eq("891260000000001")
      expect(result.proc_xml).to include("<procEventoNFe").and(include(result.event_xml))
      expect(result.filename).to eq("#{signed.key}_110140_01-procEventoNFe.xml")
      call = transport.calls.first
      expect(call.url).to eq("https://hom1.nfe.fazenda.gov.br/NFeRecepcaoEvento4/NFeRecepcaoEvento4.asmx")
      expect(DfeRb::Nfe::Signature.verify(result.event_xml)).to be(true)
      detail = Nokogiri::XML(result.event_xml).remove_namespaces!.at_xpath("//infEvento")
      expect(detail["Id"]).to eq("ID110140#{signed.key}01")
      expect(detail.at_xpath("cOrgao").text).to eq("91")
      expect(detail.at_xpath("detEvento").children.map { |node| "#{node.name}=#{node.children.any?(&:element?) ? "…" : node.text}" }).to eq(
        ["descEvento=EPEC", "cOrgaoAutor=35", "tpAutor=1", "verAplic=dfe_rb #{DfeRb::VERSION}", "dhEmi=#{text(signed.xml, "dhEmi")}",
          "tpNF=1", "IE=111111111111", "dest=…"]
      )
      expect(detail.at_xpath("detEvento/dest").children.map { |node| "#{node.name}=#{node.text}" }).to eq(
        ["UF=RJ", "CNPJ=11222333000181", "vNF=20.00", "vICMS=0.00", "vST=0.00"]
      )
    end

    it "prepares the event to be stored and sent as it is" do
      transport.answer(:manifestation, ret_epec(signed.key))
      prepared = client.prepare_epec(signed)

      result = client.epec(prepared)

      expect(prepared.key).to eq(signed.key)
      expect(result.event_xml).to eq(prepared.xml)
      expect(transport.calls.first.xml).to include(prepared.xml)
    end

    it "refuses a note that isn't one, and issuers of PR and PB" do
      expect { client.epec(client.sign(simples_invoice(client))) }.to raise_error(DfeRb::ValidationError, /tpEmis 4 \(got 1\)/)

      tree = DfeRb::Nfe::Document.new(signed.xml)
      allow(tree).to receive(:to_infnfe).and_wrap_original { |original| original.call.tap { |inf| inf["emit"]["enderEmit"]["UF"] = "PR" } }
      expect { DfeRb::Nfe::Epec.build(tree, environment: :homologacao) }.to raise_error(DfeRb::ValidationError, /PR can't register an EPEC/)
    end
  end
end
