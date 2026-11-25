RSpec.describe DfeRb::Cte::Client do
  let(:transport) { FakeTransport.new }
  let(:client) { cte_client(transport) }

  describe "#status" do
    it "queries CTeStatusServicoV4 and parses the result" do
      transport.answer(:status, ret_cons_stat_serv_cte)
      result = client.status
      expect(result).to be_online
      expect(result.code).to eq(107)
      expect(transport.calls.first.service).to eq(:status)
      expect(transport.calls.first.xml).to include("<cUF>35</cUF>")
    end
  end

  describe "#authorize and #authorize!" do
    it "signs, gzips, sends to CTeRecepcaoSincV4, and builds cteProc" do
      waybill = road_waybill(client)
      signed = client.sign(waybill)
      transport.answer(:authorization, ret_cte(prot_cte(signed.key, digest: signed.digest_value)))

      result = client.authorize!(signed)
      expect(result).to be_authorized
      expect(result.filename).to eq("#{signed.key}-procCTe.xml")
      expect(result.proc_xml).to include("<cteProc", "<CTe", "<protCTe")
      expect(DfeRb::Cte::Requests.unpack(transport.calls.first.xml)).to eq(signed.xml)
    end

    it "accepts cStat 150 (authorized late) as authorized" do
      signed = client.sign(road_waybill(client))
      transport.answer(:authorization, ret_cte(prot_cte(signed.key, code: 150, message: "Autorizado fora de prazo", digest: signed.digest_value)))

      result = client.authorize!(signed)
      expect(result).to be_authorized
    end

    it "routes SVC waybills to the state's SVC and rejects mismatched SVC emission type" do
      svc_waybill = road_waybill(client) { |cte| cte.contingency :svc }
      signed = client.sign(svc_waybill)
      transport.answer(:authorization, ret_cte(prot_cte(signed.key, digest: signed.digest_value)))

      result = client.authorize!(signed)
      expect(result).to be_authorized
      expect(transport.calls.first.url).to include("svrs.rs.gov.br")

      wrong_svc = road_waybill(client) { |cte| cte.contingency :svc_sp }
      expect { client.authorize(wrong_svc) }.to raise_error(DfeRb::ValidationError, /G011, rej\. 516/)
    end

    it "recovers from a lost response when SEFAZ holds the same document" do
      signed = client.sign(road_waybill(client))
      transport.answer(:authorization, DfeRb::TransportError.new("ReadTimeout", maybe_processed: true))
      transport.answer(:consult, ret_cons_sit_cte(protocol_xml: prot_cte(signed.key, digest: signed.digest_value)))

      result = client.authorize(signed)
      expect(result).to be_authorized
      expect(result).to be_recovered
    end

    it "raises Conflict on recovery when SEFAZ holds a different digest" do
      signed = client.sign(road_waybill(client))
      transport.answer(:authorization, ret_cte(prot_cte(signed.key, code: 204, message: "Duplicidade", protocol: nil)))
      transport.answer(:consult, ret_cons_sit_cte(protocol_xml: prot_cte(signed.key, digest: "DIFFERENTDIGESTVALUE1234567=")))

      expect { client.authorize(signed) }.to raise_error(DfeRb::Cte::Conflict, /differs from the stored one/)
    end

    it "raises Rejected or ConsumptionBlocked from authorize!" do
      signed = client.sign(road_waybill(client))
      transport.answer(:authorization, ret_cte(prot_cte(signed.key, code: 656, message: "Consumo indevido", protocol: nil)))
      expect { client.authorize!(signed) }.to raise_error(DfeRb::Cte::ConsumptionBlocked)

      transport.replace(:authorization, ret_cte(prot_cte(signed.key, code: 203, message: "Emissor nao habilitado", protocol: nil)))
      expect { client.authorize!(signed) }.to raise_error(DfeRb::Cte::Rejected)
    end
  end

  describe "#consult" do
    it "returns status, protocol, and parsed events" do
      key = cte_key
      ev_xml = %(<procEventoCTe xmlns="#{cte_ns}" versao="4.00"><eventoCTe versao="4.00"><infEvento Id="ID110111#{key}001"><tpEvento>110111</tpEvento><nSeqEvento>1</nSeqEvento><detEvento versaoEvento="4.00"><evCancCTe><descEvento>Cancelamento</descEvento></evCancCTe></detEvento></infEvento></eventoCTe><retEventoCTe versao="4.00"><infEvento><cStat>135</cStat><xMotivo>Registrado</xMotivo><nProt>135260000000999</nProt></infEvento></retEventoCTe></procEventoCTe>)
      transport.answer(:consult, ret_cons_sit_cte(code: 101, message: "Cancelado", protocol_xml: prot_cte(key), events: [ev_xml]))

      result = client.consult(key)
      expect(result).to be_canceled
      expect(result).to be_found
      expect(result.events.size).to eq(1)
      expect(result.events.first.type).to eq("110111")
    end
  end

  describe "events" do
    let(:key) { cte_key }
    let(:protocol) { "135260000000123" }

    it "sends cancellation (110111) with 3-digit sequence in Id" do
      transport.answer(:event, ret_evento_cte(key, type: "110111"))
      result = client.cancel(key, protocol: protocol, reason: "Cancelamento por erro de digitacao")
      expect(result).to be_registered
      expect(result.filename).to eq("#{key}_110111_001-procEventoCTe.xml")
      expect(result.event_xml).to include(%(Id="ID110111#{key}001"))
      expect(result.proc_xml).to include("<procEventoCTe")
    end

    it "sends Carta de Correção (110110) and refuses forbidden fields" do
      transport.answer(:event, ret_evento_cte(key, type: "110110"))
      result = client.correct(key, changes: [{group: "compl", field: "xObs", value: "Observacao corrigida"}])
      expect(result).to be_registered

      expect { client.correct(key, changes: [{group: "ide", field: "CFOP", value: "5353"}]) }
        .to raise_error(ArgumentError, /MOC 13\.1, rej\. 681/)
    end

    it "sends disagreement (610110) and cancel_disagreement (610111) signed by the taker" do
      taker_client = DfeRb::Cte::Client.new(certificate: cte_certificate(cnpj: cte_sender), uf: "SP", transport: transport)
      transport.answer(:event, ret_evento_cte(key, type: "610110"), ret_evento_cte(key, type: "610111"))
      res = taker_client.disagree(key, reason: "Frete cobrado em desacordo com o combinado")
      expect(res).to be_registered
      expect(res.event_xml).to include("<CNPJ>#{cte_sender}</CNPJ>")

      cancel = taker_client.cancel_disagreement(key, protocol: "135260000000999")
      expect(cancel).to be_registered
    end

    it "sends delivery receipt (110180) and cancellation (110181)" do
      transport.answer(:event, ret_evento_cte(key, type: "110180"), ret_evento_cte(key, type: "110181"))
      res = client.deliver(key, protocol: protocol, document: "123456789", name: "Joao Silva",
        image: "fake-signature-bytes", nfe: [cte_key(model: 55, tax_id: cte_sender)])
      expect(res).to be_registered
      expect(res.event_xml).to include("<hashEntrega>", "<infEntrega>")

      cancel = client.cancel_delivery(key, protocol: protocol, event_protocol: "135260000000999")
      expect(cancel).to be_registered
    end

    it "sends delivery failure (110190) and cancellation (110191)" do
      transport.answer(:event, ret_evento_cte(key, type: "110190"), ret_evento_cte(key, type: "110191"))
      res = client.report_delivery_failure(key, protocol: protocol, reason: :recipient_not_found, attempt: 1)
      expect(res).to be_registered
      expect(res.event_xml).to include("<tpMotivo>1</tpMotivo>", "<nTentativa>001</nTentativa>")

      cancel = client.cancel_delivery_failure(key, protocol: protocol, event_protocol: "135260000000999")
      expect(cancel).to be_registered
    end

    it "sends multimodal record (110160), payment link (110300), and cancel payment link (110301)" do
      transport.answer(
        :event,
        ret_evento_cte(key, type: "110160"),
        ret_evento_cte(key, type: "110300"),
        ret_evento_cte(key, type: "110301")
      )
      expect(client.record_multimodal(key, text: "Registro de transbordo rodoviario concluido")).to be_registered

      link = client.link_payment(key, protocol: protocol, method: :pix, transaction_id: "E1234567890",
        receiver_cnpj: cte_issuer, psp_cnpj_base: "11444777")
      expect(link).to be_registered

      expect(client.cancel_payment_link(key, protocol: protocol, event_protocol: "135260000000999")).to be_registered
    end
  end
end
