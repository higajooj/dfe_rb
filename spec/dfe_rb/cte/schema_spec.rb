RSpec.describe DfeRb::Cte::Schema do
  it "loads the CT-e 4.00 schema with all six modals grafted under infModal" do
    root = described_class.cte
    expect(root.tag).to eq("CTe")
    inf_modal = root.find("infCte").find("infCTeNorm").find("infModal")
    modal_tags = inf_modal.each_element.map(&:tag)
    expect(modal_tags).to eq(%w[rodo aereo aquav ferrov duto multimodal])
  end
end

RSpec.describe DfeRb::Cte::Schemas do
  describe ".cte_issues" do
    it "accepts a valid unsigned road waybill" do
      xml = road_waybill.to_xml
      expect(described_class.cte_issues(xml)).to eq([])
    end

    it "rejects namespace prefixes" do
      xml = %(<cte:CTe xmlns:cte="#{DfeRb::Cte::Signature::CTE}"/>)
      expect(described_class.cte_issues(xml)).to include(match(/namespace prefixes are not allowed/))
    end

    it "flags a modal mismatch between ide/modal and infModal" do
      xml = road_waybill.to_xml.sub("<modal>01</modal>", "<modal>02</modal>")
      expect(described_class.cte_issues(xml)).to include(match(/G026, rej\. 580/))
    end

    it "validates modal-specific fields against the modal XSD" do
      xml = road_waybill.to_xml.sub("<RNTRC>12345678</RNTRC>", "<RNTRC>BAD</RNTRC>")
      expect(described_class.cte_issues(xml)).not_to be_empty
    end
  end

  describe ".event_issues" do
    it "validates a signed cancellation event and its detail schema" do
      key = DfeRb::Cte::AccessKey.parse(cte_key)
      detail = DfeRb::Cte::Requests.cancellation(protocol: "135260000000123", reason: "Cancelamento por erro de digitacao")
      unsigned = DfeRb::Cte::Requests.event(key: key, type: "110111", sequence: 1, detail: detail, environment: :homologacao, at: Time.now)
      signed = DfeRb::Cte::Signature.sign_event(unsigned, cte_certificate)
      expect(described_class.event_issues(signed)).to eq([])
    end

    it "validates NT 2026.004 presumed credit (211110) and NT 2026.005 tax-admin SN events (412140, 412141)" do
      key = DfeRb::Cte::AccessKey.parse(cte_key)
      cred = DfeRb::Cte::Requests.presumed_credit(
        base: BigDecimal("500.00"), code: "01",
        ibs: {rate: BigDecimal("0.10"), amount: BigDecimal("0.50")},
        cbs: {rate: BigDecimal("0.90"), amount: BigDecimal("4.50")},
        payment_declaration: DfeRb::Cte::Requests::PRESUMED_CREDIT_DECLARATION
      )
      signed_cred = DfeRb::Cte::Signature.sign_event(
        DfeRb::Cte::Requests.event(key: key, type: "211110", sequence: 1, detail: cred, environment: :homologacao, at: Time.now, author: cte_sender),
        cte_certificate(cnpj: cte_sender)
      )
      expect(described_class.event_issues(signed_cred)).to eq([])

      sn_detail = %(<evTributacaoSN><descEvento>Tributacao do Simples Nacional</descEvento><nProt>135260000000123</nProt>) +
        %(<gTribItemSN nItem="1"><vRBSNItem>500.00</vRBSNItem><tpRBSN>1</tpRBSN><pIBSSN>1.0000</pIBSSN><vIBSSN>5.00</vIBSSN>) +
        %(<pCBSSN>0.5000</pCBSSN><vCBSSN>2.50</vCBSSN></gTribItemSN>) +
        %(<gTotalSN><vRBSNTot>500.00</vRBSNTot><vIBSSNTot>5.00</vIBSSNTot><vCBSSNTot>2.50</vCBSSNTot></gTotalSN></evTributacaoSN>)
      signed_sn = DfeRb::Cte::Signature.sign_event(
        DfeRb::Cte::Requests.event(key: key, type: "412140", sequence: 1, detail: sn_detail, environment: :homologacao, at: Time.now),
        cte_certificate
      )
      expect(described_class.event_issues(signed_sn)).to eq([])

      canc_sn = %(<evCancTribSN><descEvento>Cancelamento da Tributacao do Simples Nacional</descEvento>) +
        %(<nProt>135260000000123</nProt><nProtEvTribSN>135260000000999</nProtEvTribSN></evCancTribSN>)
      signed_canc_sn = DfeRb::Cte::Signature.sign_event(
        DfeRb::Cte::Requests.event(key: key, type: "412141", sequence: 1, detail: canc_sn, environment: :homologacao, at: Time.now),
        cte_certificate
      )
      expect(described_class.event_issues(signed_canc_sn)).to eq([])

      expect(described_class::EVENTS).not_to have_key("110170")
    end
  end
end
