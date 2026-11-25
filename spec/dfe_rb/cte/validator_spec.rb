RSpec.describe DfeRb::Cte::Validator do
  def issues_for(**options, &block)
    road_waybill(**options, &block).issues
  end

  it "checks CFOP validity, scope prefix, and out-of-state 5932/6932 rules" do
    expect(issues_for { |cte| cte.cfop "5102" }).to include(match(/G049, rej\. 676/))
    expect(issues_for { |cte| cte.cfop "5353" }).to include(match(/G050, rej\. 519/))
    expect(issues_for { |cte| cte.cfop "6932" }).to include(match(/G052, rej\. 908/))
    expect(issues_for { |cte| cte.origin "Belo Horizonte", "MG" }).to include(match(/G051, rej\. 524/))
  end

  it "checks reserved series and contingency rules" do
    expect(issues_for { |cte| cte.series 890 }).to include(match(/G006, rej\. 670/))
    expect(issues_for(certificate: cte_certificate) { |cte| cte.contingency :offline })
      .to include(match(/G009, rej\. 587/))
    expect(issues_for(certificate: cte_certificate) do |cte|
      cte.contingency :offline, since: Time.now + 3600, reason: "Sem internet na filial agora"
    end).to include(match(/G010, rej\. 588/))
  end

  it "checks taker IE rules and rejects exempt taker in disallowed states" do
    expect(issues_for do |cte|
      cte.sender tax_id: cte_sender, name: "REMETENTE SA", state_registration: "ISENTO", address: cte_sp_address
    end).to include(match(/G024, rej\. 617/))

    expect(issues_for do |cte|
      cte.taker tax_id: cte_sender, name: "REMETENTE SA", state_registration: "222222222222", address: cte_sp_address
    end).to include(match(/G156, rej\. 799/))
  end

  it "checks service value limits, receivable cap, and ICMS math" do
    expect(issues_for { |cte| cte.freight total: "500.00", receivable: "600.00" })
      .to include(match(/G048, rej\. 531/))
    expect(issues_for { |cte| cte.icms cst: "00", base: "500.00", rate: "12.00", amount: "99.00" })
      .to include(match(/G047, rej\. 675/))
  end

  it "checks duplicate and old NF-e keys" do
    dup_key = cte_key(model: 55, number: 99, tax_id: cte_sender)
    expect(issues_for { |cte| cte.nfe [dup_key, dup_key] }).to include(match(/G039, rej\. 527/))

    old_key = cte_key(model: 55, number: 100, tax_id: cte_sender, issued_at: Time.new(2024, 1, 10, 10, 0, 0, "-03:00"))
    expect(issues_for { |cte| cte.nfe old_key }).to include(match(/G040a, rej\. 930/))
  end

  it "checks previous documents and multimodal-linked service rules" do
    expect(issues_for { |cte| cte.service_type :subcontracting }).to include(match(/G059, rej\. 521/))
    expect(issues_for do |cte|
      cte.previous_cte cte_key(number: 7), issuer: {tax_id: cte_sender, state_registration: "222222222222", state: "SP", name: "EMP"}
    end).to include(match(/G060, rej\. 747/))
  end

  it "checks autXML duplicates and overlap with parties" do
    expect(issues_for { |cte| cte.authorized_downloader cte_sender }).to include(match(/G196, rej\. 828/))
    expect(issues_for { |cte| cte.authorized_downloader ["00000000000191", "00000000000191"] })
      .to include(match(/G195, rej\. 715/))
  end

  it "checks IBS/CBS CST compatibility and vTotDFe" do
    expect(issues_for { |cte| cte.ibs_cbs cst: "200", class_code: "000001" })
      .to include(match(/NT 2025\.001 004, rej\. 313/))
    expect(issues_for do |cte|
      cte.ibs_cbs class_code: "000001"
      cte.total_dfe "999.00"
    end).to include(match(/NT 2026\.004 §4, rej\. 365/))
  end

  it "checks payment link methods and receiver CNPJ" do
    expect(issues_for do |cte|
      cte.payment_link "99", transaction_id: "TX1", receiver_cnpj: cte_issuer, psp_cnpj_base: "11444777"
    end).to include(match(/NT 2026\.001 L12, rej\. 1003/))
  end
end
