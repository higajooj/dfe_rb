RSpec.describe DfeRb::Cte::Waybill do
  it "derives defaults, cities, ICMS, access key, QR code, and homologação party names" do
    waybill = road_waybill
    expect(waybill).to be_valid
    xml = waybill.to_xml
    doc = Nokogiri::XML(xml)
    ns = {"cte" => DfeRb::Cte::Signature::CTE}

    expect(doc.at_xpath("/cte:CTe/cte:infCte/@versao", ns).value).to eq("4.00")
    expect(doc.at_xpath("//cte:ide/cte:mod", ns).text).to eq("57")
    expect(doc.at_xpath("//cte:ide/cte:modal", ns).text).to eq("01")
    expect(doc.at_xpath("//cte:ide/cte:cMunEnv", ns).text).to eq("3550308")
    expect(doc.at_xpath("//cte:ide/cte:cMunIni", ns).text).to eq("3550308")
    expect(doc.at_xpath("//cte:ide/cte:cMunFim", ns).text).to eq("3304557")
    expect(doc.at_xpath("//cte:ide/cte:indIEToma", ns).text).to eq("1")
    expect(doc.at_xpath("//cte:rem/cte:xNome", ns).text).to eq(DfeRb::Cte::Resolver::HOMOLOGACAO_NAME)
    expect(doc.at_xpath("//cte:vPrest/cte:vRec", ns).text).to eq("500.00")
    expect(doc.at_xpath("//cte:imp/cte:ICMS/cte:ICMS00/cte:vBC", ns).text).to eq("500.00")
    expect(doc.at_xpath("//cte:imp/cte:ICMS/cte:ICMS00/cte:vICMS", ns).text).to eq("60.00")
    expect(doc.at_xpath("//cte:infCarga/cte:infQ/cte:tpMed", ns).text).to eq("PESO BRUTO")
    expect(waybill.key.model).to eq(57)
    expect(waybill.qr_code).to include("chCTe=#{waybill.key}&tpAmb=2")
  end

  it "keeps numeric code and emission time stable across resolves" do
    waybill = road_waybill
    expect(waybill.key).to eq(waybill.key)
    expect(waybill.to_xml).to eq(waybill.to_xml)
  end

  it "computes ICMS20 with base reduction, ICMSSN, and ICMSOutraUF" do
    w20 = road_waybill { |cte| cte.icms cst: "20", base_reduction: "20.00", rate: "12.00" }
    expect(w20).to be_valid
    expect(w20.resolved.dig("imp", "ICMS", "ICMS20", "vBC")).to eq(BigDecimal("400.00"))
    expect(w20.resolved.dig("imp", "ICMS", "ICMS20", "vICMS")).to eq(BigDecimal("48.00"))

    wsn = road_waybill(ibs_cbs: nil) do |cte|
      cte.issuer tax_id: cte_issuer, name: "TRANSPORTES LTDA", state_registration: "111111111111",
        tax_regime: :simples, address: cte_sp_address
      cte.icms simples: true
    end
    expect(wsn).to be_valid
    expect(wsn.resolved.dig("imp", "ICMS", "ICMSSN")).to eq("CST" => "90", "indSN" => 1)

    wou = road_waybill { |cte| cte.icms other_state: true, rate: "7.00" }
    expect(wou).to be_valid
    expect(wou.resolved.dig("imp", "ICMS", "ICMSOutraUF", "vICMSOutraUF")).to eq(BigDecimal("35.00"))
  end

  it "derives IBS/CBS rates, amounts, and vTotDFe in 2026 and 2027" do
    clock_2026 = Struct.new(:now).new(Time.new(2026, 11, 24, 10, 0, 0, "-03:00"))
    w26 = road_waybill(clock: clock_2026) { |cte| cte.ibs_cbs class_code: "000001" }
    expect(w26).to be_valid
    expect(w26.resolved.dig("imp", "IBSCBS", "CST")).to eq("000")
    expect(w26.resolved.dig("imp", "IBSCBS", "gIBSCBS", "vIBS")).to eq(BigDecimal("0.50"))
    expect(w26.resolved.dig("imp", "IBSCBS", "gIBSCBS", "gCBS", "vCBS")).to eq(BigDecimal("4.50"))
    expect(w26.resolved.dig("imp", "vTotDFe")).to eq(BigDecimal("500.00"))

    clock_2027 = Struct.new(:now).new(Time.new(2027, 1, 15, 10, 0, 0, "-03:00"))
    w27 = road_waybill(clock: clock_2027) do |cte|
      cte.nfe cte_key(model: 55, tax_id: cte_sender, issued_at: clock_2027.now)
      cte.ibs_cbs class_code: "000001", cbs: {rate: "8.80"}
    end
    expect(w27).to be_valid
    expect(w27.resolved.dig("imp", "IBSCBS", "gIBSCBS", "vIBS")).to eq(BigDecimal("0.50"))
    expect(w27.resolved.dig("imp", "IBSCBS", "gIBSCBS", "gCBS", "vCBS")).to eq(BigDecimal("44.00"))
    expect(w27.resolved.dig("imp", "vTotDFe")).to eq(BigDecimal("544.50"))
  end

  it "supports third-party taker (toma4), technical contact CSRT hash, and payment links" do
    waybill = road_waybill(technical_contact: {
      cnpj: "99999999000191", contact: "Dev", email: "dev@example.com", phone: "11999999999",
      csrt_id: "01", csrt: "secret-token"
    }) do |cte|
      cte.taker tax_id: "00000000000191", name: "TOMADOR SA", state_registration: "444444444444", address: cte_sp_address
      cte.payment_link :pix, transaction_id: "TX123456", receiver_cnpj: cte_issuer, psp_cnpj_base: "11444777"
    end
    expect(waybill).to be_valid
    expect(waybill.resolved.dig("ide", "toma4", "toma")).to eq(4)
    expect(waybill.resolved.dig("infRespTec", "hashCSRT")).not_to be_nil
    expect(waybill.resolved.dig("pgtoVinc", "pgto", 0, "@nPag")).to eq("1")
  end

  it "supports complementary, substitution, offline contingency, and SVC waybills" do
    orig_key = cte_key(number: 1)

    comp = DfeRb::Cte::Waybill.new do |cte|
      cte.number 43
      cte.cfop "6353"
      cte.nature_of_operation "Complemento de frete"
      cte.modal :road
      cte.issuer tax_id: cte_issuer, name: "TRANSPORTES LTDA", state_registration: "111111111111",
        tax_regime: :normal, address: cte_sp_address
      cte.sender tax_id: cte_sender, name: "REMETENTE SA", state_registration: "222222222222", address: cte_sp_address
      cte.recipient tax_id: cte_recipient, name: "DESTINATARIO SA", state_registration: "333333333333", address: cte_rj_address
      cte.taker :sender
      cte.freight total: "100.00"
      cte.icms cst: "00", rate: "12.00"
      cte.ibs_cbs class_code: "000001"
      cte.complement orig_key
    end
    expect(comp).to be_valid
    expect(comp.resolved.dig("ide", "tpCTe")).to eq(1)

    sub = road_waybill { |cte| cte.substitute orig_key, change_taker: true }
    expect(sub).to be_valid
    expect(sub.resolved.dig("ide", "tpCTe")).to eq(3)
    expect(sub.resolved.dig("infCTeNorm", "infCteSub", "indAlteraToma")).to eq(1)

    now = Time.now
    offline = road_waybill(certificate: cte_certificate) do |cte|
      cte.contingency :offline, since: now - 60, reason: "Sem conexao com a internet na filial"
    end
    expect(offline).to be_valid
    expect(offline.key.emission_type).to eq(2)
    expect(offline.qr_code).to include("&sign=")

    svc = road_waybill { |cte| cte.contingency :svc }
    expect(svc).to be_valid
    expect(svc.key.emission_type).to eq(7)
    expect(svc.qr_code).not_to include("&sign=")
  end

  it "supports air, water, rail, pipeline, and multimodal modals" do
    base = lambda do |&extra|
      DfeRb::Cte::Waybill.new do |cte|
        cte.number 50
        cte.cfop "6353"
        cte.nature_of_operation "Transporte"
        cte.issuer tax_id: cte_issuer, name: "TRANSPORTES LTDA", state_registration: "111111111111",
          tax_regime: :normal, address: cte_sp_address
        cte.sender tax_id: cte_sender, name: "REMETENTE SA", state_registration: "222222222222", address: cte_sp_address
        cte.recipient tax_id: cte_recipient, name: "DESTINATARIO SA", state_registration: "333333333333", address: cte_rj_address
        cte.taker :sender
        cte.freight total: "500.00"
        cte.icms cst: "00", rate: "12.00"
        cte.ibs_cbs class_code: "000001"
        cte.cargo value: "5000.00", product: "Carga" do |c|
          c.measure :kg, "100.0"
        end
        cte.nfe cte_key(model: 55, tax_id: cte_sender)
        extra.call(cte)
      end
    end

    air = base.call { |cte| cte.air dPrevAereo: "2026-11-30", natCarga: {}, tarifa: {CL: "G", vTar: "10.00"} }
    expect(air).to be_valid
    expect(air.resolved.dig("ide", "modal")).to eq("02")

    water = base.call { |cte| cte.water vPrest: "500.00", vAFRMM: "0.00", xNavio: "NAVIO 1", direc: "N", irin: "1234567890" }
    expect(water).to be_valid
    expect(water.resolved.dig("ide", "modal")).to eq("03")

    rail = base.call { |cte| cte.rail tpTraf: "0", fluxo: "FLX01" }
    expect(rail).to be_valid
    expect(rail.resolved.dig("ide", "modal")).to eq("04")

    pipeline = base.call { |cte| cte.pipeline dIni: "2026-11-01", dFim: "2026-11-30" }
    expect(pipeline).to be_valid
    expect(pipeline.resolved.dig("ide", "modal")).to eq("05")

    multi = base.call { |cte| cte.multimodal cotm: "1234567890", negotiable: :non_negotiable }
    expect(multi).to be_valid
    expect(multi.resolved.dig("ide", "modal")).to eq("06")
  end
end
