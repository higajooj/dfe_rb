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

  it "enforces offline contingency (tpEmis 2) rollout dates and keeps EPEC (tpEmis 4) for reconciliation" do
    before_prod = Struct.new(:now).new(Time.new(2026, 12, 13, 23, 59, 0, "-03:00"))
    after_prod = Struct.new(:now).new(Time.new(2026, 12, 14, 0, 0, 0, "-03:00"))
    before_hom = Struct.new(:now).new(Time.new(2026, 10, 25, 23, 59, 0, "-03:00"))

    expect(issues_for(environment: :production, certificate: cte_certificate, clock: before_prod) do |cte|
      cte.contingency :offline, since: before_prod.now - 60, reason: "Sem conexao com a internet na filial"
    end).to include(match(/offline contingency.*14\/12\/2026/))

    expect(issues_for(environment: :production, certificate: cte_certificate, clock: after_prod) do |cte|
      cte.contingency :offline, since: after_prod.now - 60, reason: "Sem conexao com a internet na filial"
    end).to eq([])

    expect(issues_for(environment: :homologacao, certificate: cte_certificate, clock: before_hom) do |cte|
      cte.contingency :offline, since: before_hom.now - 60, reason: "Sem conexao com a internet na filial"
    end).to include(match(/offline contingency.*26\/10\/2026/))

    expect(issues_for(environment: :production, certificate: cte_certificate, clock: after_prod) do |cte|
      cte.contingency :epec
    end).to eq([])
  end

  it "enforces NT 2026.002 IBS/CBS requirement in homologação only and NT 2026.005 CRT/regime matrix" do
    after_jul = Struct.new(:now).new(Time.new(2026, 7, 1, 0, 0, 0, "-03:00"))
    before_jul = Struct.new(:now).new(Time.new(2026, 6, 30, 23, 59, 0, "-03:00"))
    after_sn = Struct.new(:now).new(Time.new(2026, 11, 20, 10, 0, 0, "-03:00"))

    expect(issues_for(ibs_cbs: nil, clock: after_jul)).to include(match(/NT 2026\.002 001, rej\. 310/))
    expect(issues_for(ibs_cbs: nil, clock: before_jul)).to eq([])
    expect(issues_for(ibs_cbs: nil, environment: :production, clock: after_jul)).to eq([])

    expect(issues_for(ibs_cbs: nil, clock: after_sn) do |cte|
      cte.issuer tax_id: cte_issuer, name: "MEI TRANSPORTE", state_registration: "111111111111",
        tax_regime: :mei, address: cte_sp_address
      cte.icms simples: true
      cte.ibs_cbs class_code: "000001", gIBSCBS: {vBC: "500.00", gIBSUF: {pIBSUF: "0.10", vIBSUF: "0.50"}, gIBSMun: {pIBSMun: "0.00", vIBSMun: "0.00"}, vIBS: "0.50", gCBS: {pCBS: "0.90", vCBS: "4.50"}}
    end).to include(match(/NT 2026\.005 §6 11, rej\. 1107/))

    expect(issues_for(ibs_cbs: nil, clock: after_sn) do |cte|
      cte.issuer tax_id: cte_issuer, name: "SN TRANSPORTE", state_registration: "111111111111",
        tax_regime: :simples, address: cte_sp_address
      cte.icms simples: true
      cte.ibs_cbs class_code: "000001"
    end).to include(match(/NT 2026\.005 §6 03, rej\. 1101/))

    crt2 = road_waybill(ibs_cbs: nil, clock: after_sn) do |cte|
      cte.issuer tax_id: cte_issuer, name: "SN EXCESSO", state_registration: "111111111111",
        tax_regime: :simples_excess, address: cte_sp_address
      cte.ibs_cbs class_code: "000001", simples: {cbs: {rate: "0.50", amount: "2.50"}}
    end
    expect(crt2.resolved.dig("imp", "IBSCBS", "gIBSCBS", "gCBS", "pCBS")).to eq(BigDecimal(0))
    expect(crt2).to be_valid

    expect(issues_for(ibs_cbs: nil, clock: after_sn) do |cte|
      cte.issuer tax_id: cte_issuer, name: "SN EXCESSO", state_registration: "111111111111",
        tax_regime: :simples_excess, address: cte_sp_address
      cte.ibs_cbs class_code: "000001", cbs: {rate: "0.90"}, simples: {cbs: {rate: "0.50", amount: "2.50"}}
    end).to include(match(/NT 2026\.005 §6 05, rej\. 316/))

    expect(issues_for(ibs_cbs: nil, clock: after_sn) do |cte|
      cte.issuer tax_id: cte_issuer, name: "SN REGULAR", state_registration: "111111111111",
        tax_regime: :simples, ibs_cbs_regime: 2, address: cte_sp_address
      cte.icms simples: true
    end).to include(match(/NT 2026\.005 §4 01, rej\. 1090/))
  end

  it "validates CPF issuer series (920..969) vs CNPJ issuer series" do
    expect(issues_for(ibs_cbs: nil) do |cte|
      cte.issuer tax_id: "52998224725", name: "TAC", state_registration: "111111111111",
        tax_regime: :simples, address: cte_sp_address
      cte.icms simples: true
      cte.series 1
    end).to include(match(/CPF issuer must use series 920 to 969/))

    expect(issues_for { |cte| cte.series 920 }).to include(match(/series 920 to 969 are reserved for CPF/))
  end
end
