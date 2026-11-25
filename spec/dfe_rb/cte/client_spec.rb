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

      expect { client.authorize(signed) }.to raise_error(DfeRb::Cte::Conflict, /digest DIFFERENTDIGESTVALUE1234567=/)
    end

    it "raises Rejected or ConsumptionBlocked from authorize!" do
      signed = client.sign(road_waybill(client))
      transport.answer(:authorization, ret_cte(prot_cte(signed.key, code: 656, message: "Consumo indevido", protocol: nil)))
      expect { client.authorize!(signed) }.to raise_error(DfeRb::Cte::ConsumptionBlocked)

      transport.replace(:authorization, ret_cte(prot_cte(signed.key, code: 203, message: "Emissor nao habilitado", protocol: nil)))
      expect { client.authorize!(signed) }.to raise_error(DfeRb::Cte::Rejected)
    end

    it "rejects outer cStat 100 without protCTe and routes it through recovery" do
      signed = client.sign(road_waybill(client))
      transport.answer(:authorization, ret_cte(nil, code: 100, message: "Autorizado o uso do CT-e"))
      transport.answer(:consult, ret_cons_sit_cte(code: 217, message: "CT-e nao consta na base"))

      expect { client.authorize!(signed) }.to raise_error(DfeRb::Cte::InvalidResponse, /without protCTe/)

      transport.replace(:authorization, ret_cte(nil, code: 100, message: "Autorizado o uso do CT-e"))
      transport.replace(:consult, ret_cons_sit_cte(protocol_xml: prot_cte(signed.key, digest: signed.digest_value)))
      recovered = client.authorize!(signed)
      expect(recovered).to be_authorized
      expect(recovered).to be_recovered
      expect(recovered.proc_xml).to include("<protCTe")
    end

    it "rejects incomplete protCTe and wrong-key or wrong-env protocols during recovery" do
      signed = client.sign(road_waybill(client))
      incomplete = prot_cte(signed.key, code: 100, protocol: nil, digest: signed.digest_value)
      transport.answer(:authorization, ret_cte(incomplete))
      expect { client.authorize!(signed, recover: false) }.to raise_error(DfeRb::Cte::InvalidResponse, /incomplete authorization protocol/)

      other_key = cte_key(number: 999)
      transport.replace(:authorization, ret_cte(prot_cte(signed.key, code: 204, message: "Duplicidade", protocol: nil)))
      transport.replace(:consult, ret_cons_sit_cte(protocol_xml: prot_cte(other_key, digest: signed.digest_value)))
      expect { client.authorize(signed) }.to raise_error(DfeRb::Cte::Conflict, /answered about #{other_key}/)

      transport.replace(:consult, ret_cons_sit_cte(environment: "1", protocol_xml: prot_cte(signed.key, environment: "1", digest: signed.digest_value)))
      expect { client.authorize(signed) }.to raise_error(DfeRb::Cte::InvalidResponse, /tpAmb 1/)
    end

    it "treats 539 as an identity conflict without consulting the submitted key and exposes existing_key" do
      signed = client.sign(road_waybill(client))
      existing_key = cte_key(number: 42, numeric_code: "87654321", issued_at: DfeRb::Cte::AccessKey.parse(signed.key).then { Time.now })
      msg = "Rejeicao: Duplicidade de CTe, com diferenca na Chave de Acesso [chCTe: #{existing_key}][nProt:135260000000123]"
      transport.answer(:authorization, ret_cte(prot_cte(signed.key, code: 539, message: msg, protocol: nil)))

      expect { client.authorize(signed) }.to raise_error(DfeRb::Cte::Conflict) { |err|
        expect(err.existing_key).to eq(existing_key)
      }
      expect(transport.calls_to(:consult)).to be_empty

      wrong_num = cte_key(number: 99, numeric_code: "87654321")
      transport.replace(:authorization, ret_cte(prot_cte(signed.key, code: 539, message: "Duplicidade [chCTe: #{wrong_num}]", protocol: nil)))
      expect { client.authorize(signed) }.to raise_error(DfeRb::Cte::Conflict) { |err|
        expect(err.existing_key).to be_nil
      }

      transport.replace(:authorization, ret_cte(prot_cte(signed.key, code: 539, message: msg, protocol: nil)))
      res = client.authorize(signed, recover: false)
      expect(res).to be_rejected
      expect(res.code).to eq(539)
    end
  end

  describe "#sign" do
    it "schema-validates SignedWaybill and rejects extra root children" do
      signed = client.sign(road_waybill(client))
      tampered = DfeRb::Cte::SignedWaybill.new(
        xml: signed.xml.sub("</CTe>", "<extra/></CTe>"),
        key: signed.key, digest_value: signed.digest_value, qr_code: signed.qr_code
      )
      expect { client.sign(tampered) }.to raise_error(DfeRb::ValidationError, /extra/)
    end

    it "verifies the embedded signer's fiscal identity under MOC E03 and preserves renewed certificates" do
      waybill = road_waybill(client)
      wrong_cert = cte_certificate(cnpj: cte_sender)
      wrong_signed_xml = DfeRb::Cte::Signature.sign_cte(waybill.to_xml, wrong_cert)

      expect { client.sign(wrong_signed_xml) }.to raise_error(DfeRb::ValidationError, /E03, rej\. 213/)

      old_cert_x509, old_key = icp_certificate(oid: DfeRb::Certificate::CNPJ_OID, value: cte_issuer)
      old_cert = DfeRb::Certificate.new(certificate: old_cert_x509, private_key: old_key)
      old_client = DfeRb::Cte::Client.new(certificate: old_cert, uf: "SP", transport: transport)
      stored = old_client.sign(road_waybill(old_client))

      renewed_cert = cte_certificate(cnpj: cte_issuer)
      renewed_client = DfeRb::Cte::Client.new(certificate: renewed_cert, uf: "SP", transport: transport)
      expect(renewed_client.sign(stored)).to eq(stored)
    end

    it "rejects offline QR codes signed with a different certificate than the XML signer" do
      cert_a_x509, key_a = icp_certificate(oid: DfeRb::Certificate::CNPJ_OID, value: cte_issuer)
      cert_a = DfeRb::Certificate.new(certificate: cert_a_x509, private_key: key_a)
      cert_b_x509, key_b = icp_certificate(oid: DfeRb::Certificate::CNPJ_OID, value: cte_issuer)
      cert_b = DfeRb::Certificate.new(certificate: cert_b_x509, private_key: key_b)
      now = Time.new(2026, 11, 24, 10, 0, 0, "-03:00")
      clock = Struct.new(:now).new(now)
      waybill = road_waybill(certificate: cert_a, clock: clock) do |cte|
        cte.contingency :offline, since: now - 60, reason: "Sem conexao com a internet na filial"
      end

      client_a = DfeRb::Cte::Client.new(certificate: cert_a, uf: "SP", transport: transport, clock: clock)
      client_b = DfeRb::Cte::Client.new(certificate: cert_b, uf: "SP", transport: transport, clock: clock)

      expect { client_b.sign(waybill) }.to raise_error(DfeRb::ValidationError, /G217, rej\. 855/)

      stored_offline = client_a.sign(waybill)
      expect(client_b.sign(stored_offline)).to eq(stored_offline)
    end

    it "rejects QR codes whose tpAmb differs from ide/tpAmb" do
      xml = road_waybill(client).to_xml.sub("&amp;tpAmb=2", "&amp;tpAmb=1")
      expect { client.sign(xml) }.to raise_error(DfeRb::ValidationError, /G214, rej\. 852/)
    end

    it "defaults CPF issuers to series 920 and checks event author identity against e-CPF" do
      cpf = "52998224725"
      cpf_cert = ecpf_certificate(cpf: cpf)
      cpf_client = DfeRb::Cte::Client.new(certificate: cpf_cert, uf: "SP", transport: transport)
      waybill = road_waybill(cpf_client, ibs_cbs: nil) do |cte|
        cte.issuer tax_id: cpf, name: "TRANSPORTADOR AUTONOMO", state_registration: "111111111111",
          tax_regime: :simples, address: cte_sp_address
        cte.icms simples: true
      end
      signed = cpf_client.sign(waybill)
      parsed_key = DfeRb::Cte::AccessKey.parse(signed.key)
      expect(parsed_key.series).to eq(920)
      expect(parsed_key).to be_person
      expect(parsed_key.issuer_id).to eq(cpf)

      transport.answer(:event, ret_evento_cte(signed.key, type: "110111"))
      res = cpf_client.cancel(signed.key, protocol: "135260000000123", reason: "Cancelamento por erro de digitacao")
      expect(res).to be_registered
      expect(res.event_xml).to include("<CPF>#{cpf}</CPF>")

      expect { client.cancel(signed.key, protocol: "135260000000123", reason: "Cancelamento por erro de digitacao") }
        .to raise_error(DfeRb::ValidationError, /E03, rej\. 202/)
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

    it "claims presumed IBS/CBS credit (211110) as taker routed exclusively to SVRS" do
      taker_client = DfeRb::Cte::Client.new(certificate: cte_certificate(cnpj: cte_sender), uf: "SP", transport: transport)
      transport.answer(:event, ret_evento_cte(key, type: "211110"))

      res = taker_client.claim_presumed_credit(
        key, base: "500.00", code: "01",
        ibs: {rate: "0.10"}, cbs: {rate: "0.90"}, payment_declaration: true
      )
      expect(res).to be_registered
      expect(transport.calls_to(:event).last.url).to include("svrs.rs.gov.br")
      expect(res.event_xml).to include("<evApropriaCredPres>", "<vBCCredPres>500.00</vBCCredPres>", "<vCredPres>0.50</vCredPres>", "<vCredPres>4.50</vCredPres>", "<xDecPag>")
    end

    it "rejects event receipts with mismatched key, type, sequence, environment, or missing protocol" do
      other_key = cte_key(number: 999)
      [
        ret_evento_cte(other_key, type: "110111"),
        ret_evento_cte(key, type: "110110"),
        ret_evento_cte(key, type: "110111", sequence: 2),
        ret_evento_cte(key, type: "110111", environment: "1"),
        ret_evento_cte(key, type: "110111", protocol: nil),
        ret_evento_cte(key, type: "110111", registered_at: nil),
        %(<wrongRoot xmlns="#{cte_ns}"><cStat>135</cStat></wrongRoot>)
      ].each do |bad|
        transport.replace(:event, bad)
        expect { client.cancel(key, protocol: protocol, reason: "Cancelamento por erro de digitacao") }
          .to raise_error(DfeRb::Cte::InvalidResponse)
      end

      transport.replace(:event, ret_evento_cte(key, type: "110111", code: 494, message: "Chave inexistente", protocol: nil, registered_at: nil, include_correlation: false))
      rejected = client.cancel(key, protocol: protocol, reason: "Cancelamento por erro de digitacao")
      expect(rejected).not_to be_registered
      expect(rejected.code).to eq(494)
      expect(rejected.proc_xml).to be_nil
    end
  end
end
