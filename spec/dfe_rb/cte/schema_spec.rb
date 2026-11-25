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
  end
end
