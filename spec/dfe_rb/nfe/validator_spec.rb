RSpec.describe DfeRb::Nfe::Validator do
  # Issues about the first item of a note with only `ide` and that item.
  def item_issues(imposto, ide: {}, extra: {}, prod: {})
    prod = {"qCom" => "1", "vUnCom" => "100.00", "qTrib" => "1", "vUnTrib" => "100.00", "vProd" => "100.00"}.merge(prod)
    tree = {"ide" => {"finNFe" => "1", "dhEmi" => "2026-09-29T10:00:00-03:00"}.merge(ide),
            "det" => [{"prod" => prod, "imposto" => imposto}.merge(extra)]}
    described_class.new(tree).issues.grep(%r{\Adet\[1\]})
  end

  it "compares an amount with the expected one rounded as the XML shows it" do
    # 100.05 x 2% = 2.001, shown as 2.00: 1.99 is within the 0.01 tolerance
    expect(item_issues({"ICMS" => {"ICMS00" => {"vBC" => "100.05", "pICMS" => "0", "vICMS" => "0", "pFCP" => "2.00", "vFCP" => "1.99"}}}))
      .to eq([])
  end

  it "leaves an amount it can't compute to SEFAZ" do
    expect(item_issues({"IS" => {"vBCIS" => "100.00", "pIS" => "1.00", "adRemIS" => "1.0000", "uTrib" => "UN", "qTrib" => "2.0000", "vIS" => "2.00"}}))
      .to eq([])
  end

  it "takes the issue year from dhEmi as given, not in UTC" do
    issues = item_issues({"IBSCBS" => {"cClassTrib" => "000001", "gIBSCBS" => {"vBC" => "100.00", "vIBS" => "0.10",
                                                                               "gIBSUF" => {"pIBSUF" => "0.10", "vIBSUF" => "0.10"}, "gCBS" => {"pCBS" => "0.90", "vCBS" => "0.90"}}}},
      ide: {"dhEmi" => "2026-12-31T22:00:00-03:00"}, extra: {"vItem" => "100.00"})

    expect(issues).to eq([])
  end

  it "requires gTribRegular and zero main rates where the classification calls for them (UB68-10, UB56-10)" do
    issues = item_issues({"IBSCBS" => {"cClassTrib" => "550001", "gIBSCBS" => {"vBC" => "100.00", "gCBS" => {"pCBS" => "0.90", "vCBS" => "0.90"}}}})

    expect(issues).to contain_exactly(a_string_matching(%r{gTribRegular: required for cClassTrib 550001 \(rej. 1065\)}),
      a_string_matching(%r{gCBS/pCBS: must be 0 .*\(rej. 1037\)}))
  end

  describe "the IBS/CBS rates of the issue year (UB18-10, UB37-10, UB56-10, UB56-20)" do
    def rates_issues(uf:, municipal:, cbs:, year: 2026, ide: {}, zone: false)
      gcbs = {"pCBS" => cbs}.merge(zone ? {"gALCZFMCBS" => {}} : {})
      group = {"gIBSUF" => {"pIBSUF" => uf}, "gIBSMun" => {"pIBSMun" => municipal}, "gCBS" => gcbs}
      item_issues({"IBSCBS" => {"cClassTrib" => "000001", "gIBSCBS" => group}}, ide: {"dhEmi" => "#{year}-06-01T10:00:00-03:00"}.merge(ide))
    end

    it "flags a rate that isn't the year's, and the CBS while its 2027 reference rate is unknown to the gem" do
      expect(rates_issues(uf: "0.10", municipal: "0", cbs: "0.90")).to eq([])
      expect(rates_issues(uf: "0.05", municipal: "0.05", cbs: "0.90")).to contain_exactly(
        "det[1]/imposto/IBSCBS/gIBSCBS/gIBSUF/pIBSUF: 0.05 is not the rate the law fixes for 2026 (0.1) (rej. 1026)",
        "det[1]/imposto/IBSCBS/gIBSCBS/gIBSMun/pIBSMun: 0.05 is not the rate the law fixes for 2026 (0.0) (rej. 1036)"
      )
      expect(rates_issues(uf: "0.05", municipal: "0.05", cbs: "8.70", year: 2027)).to eq([])
    end

    it "compares a rate as the XML writes it, to 4 places" do
      expect(rates_issues(uf: BigDecimal("0.10004"), municipal: 0, cbs: 0.3 * 3)).to eq([])
      expect(rates_issues(uf: "0.1001", municipal: "0", cbs: "0.90").size).to eq(1)
    end

    it "holds a complement of an earlier sale to the issue year's IBS rates (UB18-10, UB37-10)" do
      expect(rates_issues(uf: "0.10", municipal: "0", cbs: "8.70", year: 2027, ide: {"finNFe" => "2"}).size).to eq(2)
    end

    it "checks the 2027 CBS once its reference rate is published" do
      stub_const("DfeRb::Nfe::Rates::CBS_REFERENCE", {2027 => "8.80", 2028 => nil})

      expect(rates_issues(uf: "0.05", municipal: "0.05", cbs: "8.70", year: 2027)).to eq([])
      expect(rates_issues(uf: "0.05", municipal: "0.05", cbs: "8.80", year: 2027))
        .to eq(["det[1]/imposto/IBSCBS/gIBSCBS/gCBS/pCBS: 8.80 is not the rate the law fixes for 2027 (8.7) (rej. 1037)"])
    end

    it "wants a CBS of zero with gALCZFMCBS, and leaves a zero CBS of 2026 to SEFAZ" do
      expect(rates_issues(uf: "0.05", municipal: "0.05", cbs: "8.70", year: 2027, zone: true))
        .to eq(["det[1]/imposto/IBSCBS/gIBSCBS/gCBS/pCBS: 8.70 is not the rate the law fixes for 2027 (0.0) (rej. 1037)"])
      expect(rates_issues(uf: "0.10", municipal: "0", cbs: "0")).to eq([])
    end

    it "leaves alone a return, the credit notes of a refusal or a reduction, and a government purchase" do
      stale = {uf: "0.10", municipal: "0", cbs: "0.90", year: 2027}

      expect(rates_issues(**stale, ide: {"finNFe" => "4"})).to eq([])
      expect(rates_issues(**stale, ide: {"finNFe" => "5", "tpNFCredito" => "4"})).to eq([])
      expect(rates_issues(**stale, ide: {"gCompraGov" => {"tpEnteGov" => "1", "pRedutor" => "10.0000"}})).to eq([])
    end
  end

  it "flags PIS and COFINS charged on a normal note issued from 2027, but not on a return" do
    taxed = {"PIS" => {"PISAliq" => {"CST" => "01", "vBC" => "100.00", "pPIS" => "1.65", "vPIS" => "1.65"}},
             "COFINS" => {"COFINSNT" => {"CST" => "08"}},
             "COFINSST" => {"vBC" => "100.00", "pCOFINS" => "7.60", "vCOFINS" => "7.60"}}

    expect(item_issues(taxed, ide: {"dhEmi" => "2026-12-31T23:59:59-03:00"})).to eq([])
    expect(item_issues(taxed, ide: {"dhEmi" => "2027-01-01T00:00:00-03:00"})).to contain_exactly(
      "det[1]/imposto/PIS/pPIS: PIS/Pasep and COFINS are not charged on a note issued from 2027 (EC 132/2023, ADCT art. 126, II; LC 214/2025, art. 542)",
      "det[1]/imposto/COFINSST/pCOFINS: PIS/Pasep and COFINS are not charged on a note issued from 2027 (EC 132/2023, ADCT art. 126, II; LC 214/2025, art. 542)"
    )
    expect(item_issues(taxed, ide: {"dhEmi" => "2027-01-01T00:00:00-03:00", "finNFe" => "4"})).to eq([])
  end

  it "requires gDif where the CST calls for deferral and refuses it elsewhere (UB59-10, UB59-20)" do
    deferred = item_issues({"IBSCBS" => {"cClassTrib" => "510001", "gIBSCBS" => {"vBC" => "100.00", "gCBS" => {"pCBS" => "0.90"}}}})
    regular = item_issues({"IBSCBS" => {"cClassTrib" => "000001",
                                        "gIBSCBS" => {"vBC" => "100.00", "gCBS" => {"pCBS" => "0.90", "gDif" => {"pDif" => "10.00", "vDif" => "0.09"}, "vCBS" => "0.81"}}}})

    expect(deferred).to eq(["det[1]/imposto/IBSCBS/gIBSCBS/gCBS/gDif: required for CST 510 (rej. 1061)"])
    expect(regular).to eq(["det[1]/imposto/IBSCBS/gIBSCBS/gCBS/gDif: not allowed for CST 000 (rej. 1090)"])
  end

  describe "the cClassTrib (IT 2025.002)" do
    it "refuses a code the table lacks (UB14-10)" do
      expect(item_issues({"IBSCBS" => {"CST" => "000", "cClassTrib" => "000099"}}))
        .to eq(["det[1]/imposto/IBSCBS/cClassTrib: 000099 is not in the cClassTrib table (IT 2025.002) (rej. 1023)"])
    end

    it "takes a revoked code only on a note issued before its end (UB14-10)" do
      revoked = {"IBSCBS" => {"CST" => "220", "cClassTrib" => "220001"}}

      expect(item_issues(revoked)).to eq(["det[1]/imposto/IBSCBS/cClassTrib: 220001 is not in force on 2026-09-29, " \
        "only from 2025-05-05 until the day before 2026-01-01 (IT 2025.002) (rej. 1023)"])
      expect(item_issues(revoked, ide: {"dhEmi" => "2025-12-31T10:00:00-03:00"})).to eq([])
    end

    it "takes a code IT 2025.002 v1.70 added" do
      expect(item_issues({"IBSCBS" => {"CST" => "550", "cClassTrib" => "550027"}})).to eq([])
    end

    it "refuses a code under another CST (UB14-20) or barred from the note's model (UB14-25)" do
      now = {"dhEmi" => "2026-11-16T10:00:00-03:00"}

      expect(item_issues({"IBSCBS" => {"CST" => "200", "cClassTrib" => "000001"}}))
        .to eq(["det[1]/imposto/IBSCBS/cClassTrib: 000001 doesn't belong to CST 200, its first three digits are its CST (rej. 1024)"])
      expect(item_issues({"IBSCBS" => {"CST" => "000", "cClassTrib" => "000002"}}, ide: now))
        .to eq(["det[1]/imposto/IBSCBS/cClassTrib: 000002 can't go on a modelo 55 note (indNFe 0, IT 2025.002) (rej. 1025)"])
      expect(item_issues({"IBSCBS" => {"CST" => "000", "cClassTrib" => "000003"}}, ide: now.merge("mod" => "65")))
        .to eq(["det[1]/imposto/IBSCBS/cClassTrib: 000003 can't go on a modelo 65 note (indNFCe 0, IT 2025.002) (rej. 1025)"])
    end

    it "consults the model indicators only on a note issued since the tables' version took effect" do
      # IT 2025.002 v1.60 barred 550002 from the NF-e; a note issued before v1.71 is left alone.
      expect(item_issues({"IBSCBS" => {"CST" => "550", "cClassTrib" => "550002"}}, ide: {"dhEmi" => "2026-03-02T10:00:00-03:00"})).to eq([])
      expect(item_issues({"IBSCBS" => {"CST" => "550", "cClassTrib" => "550002"}}, ide: {"dhEmi" => "2026-10-30T10:00:00-03:00"}))
        .to eq(["det[1]/imposto/IBSCBS/cClassTrib: 550002 can't go on a modelo 55 note (indNFe 0, IT 2025.002) (rej. 1025)"])
    end
  end

  describe "the operation's presumed credit (cCredPres, IT 2025.002)" do
    def credit_issues(credit, classification: "000003", prod: {}, ide: {})
      item_issues({"IBSCBS" => {"CST" => classification[0, 3], "cClassTrib" => classification, "gCredPresOper" => credit}},
        prod: prod, ide: {"dhEmi" => "2027-01-04T10:00:00-03:00"}.merge(ide))
    end

    let(:both) { {"gIBSCredPres" => {"pCredPres" => "1.00", "vCredPres" => "1.00"}, "gCBSCredPres" => {"pCredPres" => "1.00", "vCredPres" => "1.00"}} }

    it "names a code the table lacks (UB122-10)" do
      expect(credit_issues({"vBCCredPres" => "100.00", "cCredPres" => "99"}))
        .to eq(["det[1]/imposto/IBSCBS/gCredPresOper/cCredPres: 99 is not in the cCredPres table (IT 2025.002) (rej. 1055)"])
    end

    it "refuses the group under a cClassTrib that doesn't allow it, unless the good is used (UB120-20)" do
      credit = {"vBCCredPres" => "100.00", "cCredPres" => "01"}.merge(both)

      expect(credit_issues(credit, classification: "000001"))
        .to eq(["det[1]/imposto/IBSCBS/gCredPresOper: not allowed for cClassTrib 000001, whose ind_gCredPresOper is 0 (rej. 1175)"])
      expect(credit_issues(credit, classification: "000001", prod: {"indBemMovelUsado" => "1"})).to eq([])
    end

    it "consults the indicators only on a note issued since the tables' version took effect" do
      # IT 2025.002 v1.70 stopped 410014 allowing the credit.
      expect(credit_issues({"vBCCredPres" => "100.00", "cCredPres" => "01"}, classification: "410014",
        ide: {"dhEmi" => "2026-09-29T10:00:00-03:00"})).to eq([])
      expect(credit_issues({"vBCCredPres" => "100.00", "cCredPres" => "01"}.merge(both), classification: "410014"))
        .to eq(["det[1]/imposto/IBSCBS/gCredPresOper: not allowed for cClassTrib 410014, whose ind_gCredPresOper is 0 (rej. 1175)"])
    end

    it "requires and refuses each tax's group as the code's indicators say (UB123-10 to UB127-20)" do
      cbs_only = credit_issues({"vBCCredPres" => "100.00", "cCredPres" => "05"}.merge(both))
      neither = credit_issues({"vBCCredPres" => "100.00", "cCredPres" => "01"})

      expect(cbs_only).to eq(["det[1]/imposto/IBSCBS/gCredPresOper/gIBSCredPres: not allowed for cCredPres 05 (rej. 1053)"])
      expect(neither).to eq(["det[1]/imposto/IBSCBS/gCredPresOper/gIBSCredPres: required for cCredPres 01 (rej. 1054)",
        "det[1]/imposto/IBSCBS/gCredPresOper/gCBSCredPres: required for cCredPres 01 (rej. 1058)"])
    end

    it "leaves a tax's group alone where the table leaves its indicator blank" do
      expect(credit_issues({"vBCCredPres" => "100.00", "cCredPres" => "07", "gIBSCredPres" => both["gIBSCredPres"]})).to eq([])
    end

    it "keeps a used good's credit within vProd (UB125-10, UB129-10)" do
      credit = {"vBCCredPres" => "100.00", "cCredPres" => "04",
                "gIBSCredPres" => {"pCredPres" => "1.00", "vCredPres" => "100.01"}, "gCBSCredPres" => {"pCredPres" => "1.00", "vCredPres" => "100.00"}}

      expect(credit_issues(credit))
        .to eq(["det[1]/imposto/IBSCBS/gCredPresOper/gIBSCredPres/vCredPres: a used good's credit can't exceed vProd (rej. 1107)"])
    end

    it "takes a credit in suspensive condition only for used goods, the CBS's from 2027 and the IBS's from 2033 (UB126-10, UB130-10)" do
      suspended = ->(code, tag) do
        {"vBCCredPres" => "100.00", "cCredPres" => code}.merge(both).tap { |credit| credit[tag] = credit[tag].merge("vCredPresCondSus" => "1.00") }
      end
      in2026 = {"dhEmi" => "2026-12-30T10:00:00-03:00"}

      expect(credit_issues(suspended.call("04", "gCBSCredPres"))).to eq([])
      expect(credit_issues(suspended.call("04", "gCBSCredPres"), ide: in2026))
        .to eq(["det[1]/imposto/IBSCBS/gCredPresOper/gCBSCredPres/vCredPresCondSus: only for cCredPres 04 from 2027 (rej. 1060)"])
      expect(credit_issues(suspended.call("04", "gIBSCredPres")))
        .to eq(["det[1]/imposto/IBSCBS/gCredPresOper/gIBSCredPres/vCredPresCondSus: only for cCredPres 04 from 2033 (rej. 1056)"])
      expect(credit_issues(suspended.call("04", "gIBSCredPres"), ide: {"dhEmi" => "2033-01-03T10:00:00-03:00"})).to eq([])
      expect(credit_issues(suspended.call("01", "gCBSCredPres")))
        .to eq(["det[1]/imposto/IBSCBS/gCredPresOper/gCBSCredPres/vCredPresCondSus: only for cCredPres 04 from 2027 (rej. 1060)"])
    end
  end

  it "requires the manufacturer of goods not produced on a relevant scale, with a valid CNPJ (I05e-10, I05e-20)" do
    expect(item_issues({}, prod: {"indEscala" => "N"}))
      .to eq(["det[1]/prod/CNPJFab: required when indEscala is N, not produced on a relevant scale (rej. 879)"])
    expect(item_issues({}, prod: {"indEscala" => "N", "CNPJFab" => "11222333000182"}))
      .to eq(["det[1]/prod/CNPJFab: 11222333000182 is not a valid CNPJ (check digits, rej. 489)"])
    expect(item_issues({}, prod: {"indEscala" => "N", "CNPJFab" => "11222333000181"}) + item_issues({}, prod: {"indEscala" => "S"})).to eq([])
  end

  it "requires the CEST of an item with ICMS-ST, but not in ICMSPart or an NFC-e (N23-10)" do
    expect(item_issues({"ICMS" => {"ICMSSN500" => {"CSOSN" => "500"}}}))
      .to eq(["det[1]/prod/CEST: required for an operation with ICMS-ST, CSOSN 500 (rej. 806)"])
    expect(item_issues({"ICMS" => {"ICMS60" => {"CST" => "60"}}}))
      .to eq(["det[1]/prod/CEST: required for an operation with ICMS-ST, CST 60 (rej. 806)"])
    expect(item_issues({"ICMS" => {"ICMS90" => {"CST" => "90", "vICMSST" => "1.00"}}}))
      .to eq(["det[1]/prod/CEST: required for an operation with ICMS-ST, CST 90 (rej. 806)"])

    expect(item_issues({"ICMS" => {"ICMSSN500" => {"CSOSN" => "500"}}}, prod: {"CEST" => "1004900"})).to eq([])
    expect(item_issues({"ICMS" => {"ICMSSN900" => {"CSOSN" => "900"}}})).to eq([])
    expect(item_issues({"ICMS" => {"ICMSSN102" => {"CSOSN" => "102"}}})).to eq([])
    expect(item_issues({"ICMS" => {"ICMSPart" => {"CST" => "10"}}})).to eq([])
    expect(item_issues({"ICMS" => {"ICMSSN500" => {"CSOSN" => "500"}}}, ide: {"mod" => "65"})).to eq([])
  end

  it "requires a credit note to be an entry and a debit note an exit (B25-110, B25-120)" do
    issues = ->(ide) { described_class.new({"ide" => ide}).issues.grep(%r{\Aide/tpNF}) }

    expect(issues.call("finNFe" => "5", "tpNF" => "1")).to eq(["ide/tpNF: a credit note (finNFe 5) is an entry, tpNF 0 (rej. 1161)"])
    expect(issues.call("finNFe" => "6", "tpNF" => "0")).to eq(["ide/tpNF: a debit note (finNFe 6) is an exit, tpNF 1 (rej. 1162)"])
    expect(issues.call("finNFe" => "5", "tpNF" => "0") + issues.call("finNFe" => "6", "tpNF" => "1")).to eq([])
  end

  describe "CFOP rules" do
    # Issues of a note with one item on `cfop`, from a regime normal issuer with IE in SP.
    def cfop_issues(cfop, ide: {}, emit: {}, dest: {}, prod: {}, imposto: {"ICMS" => {"ICMS00" => {"CST" => "00"}}}, inf: {}, extra: {})
      tree = {"ide" => {"finNFe" => "1", "tpNF" => "1", "dhEmi" => "2026-09-29T10:00:00-03:00"}.merge(ide),
              "emit" => {"IE" => "111111111111", "CRT" => "3", "enderEmit" => {"UF" => "SP"}}.merge(emit),
              "dest" => {"indIEDest" => "1", "enderDest" => {"UF" => "RJ"}}.merge(dest),
              "det" => [{"prod" => {"CFOP" => cfop, "NCM" => "84713012"}.merge(prod), "imposto" => imposto}.merge(extra)]}.merge(inf)
      described_class.new(tree).issues.grep(%r{\A(det\[1\]|transp)})
    end

    it "flags a CFOP that isn't in the table or can't be used in an NF-e, and nothing else about it (I08-04)" do
      expect(cfop_issues("5999", ide: {"finNFe" => "4"}))
        .to eq(["det[1]/prod/CFOP: 5999 is not in the CFOP table (IT 2023.002); look it up with " \
                "DfeRb::Nfe::Tables.cfops(matching: \"...\") (rej. 770)"])
      expect(cfop_issues("5301")).to eq(["det[1]/prod/CFOP: 5301 (Prestação de serviço de comunicação para execução de serviço…) " \
                                         "can't be used in an NF-e (rej. 770)"])
    end

    it "requires a devolução CFOP on a return and on credit notes 03 and 06 (I08-140, NT 2026.009)" do
      expect(cfop_issues("5102", ide: {"finNFe" => "4"})).to contain_exactly(a_string_matching(/5102 \(Venda.*\) is not a devolução CFOP.*rej\. 327/))
      expect(cfop_issues("1102", ide: {"finNFe" => "5", "tpNFCredito" => "06"})).to include(a_string_matching(/rej\. 327/))
      expect(cfop_issues("1102", ide: {"finNFe" => "5", "tpNFCredito" => "04"})).to eq([])
      expect(cfop_issues("5202", ide: {"finNFe" => "4"})).to eq([])
    end

    it "accepts 1949/2949 on any note the rule covers and 5949/6949 on a natural gas return (I08-140, NT 2026.009)" do
      expect(cfop_issues("1949", ide: {"finNFe" => "4"})).to eq([])
      expect(cfop_issues("1949", ide: {"finNFe" => "5", "tpNFCredito" => "03"})).to eq([])
      expect(cfop_issues("2949", ide: {"finNFe" => "5", "tpNFCredito" => "06", "tpNF" => "0", "idDest" => "2"})).to eq([])
      expect(cfop_issues("5949", ide: {"finNFe" => "4"}, prod: {"NCM" => "27112100"})).to eq([])
      expect(cfop_issues("5949", ide: {"finNFe" => "4"})).to include(a_string_matching(/rej\. 327/))
    end

    it "limits a MEI's returns to six CFOPs (I08-141)" do
      expect(cfop_issues("5202", ide: {"finNFe" => "4"}, emit: {"CRT" => "4"})).to eq([])
      expect(cfop_issues("5411", ide: {"finNFe" => "4"}, emit: {"CRT" => "4"}))
        .to contain_exactly(a_string_matching(/5411 .* can't be used on a return issued by a MEI; use 1202, .*6202 \(rej\. 1179\)/))
    end

    it "limits an issuer without IE to the CFOPs marked indExcIBSCBS, except on returns (I08-191)" do
      production = {"tpAmb" => "1", "dhEmi" => "2026-11-16T10:00:00-03:00"}
      no_ie = ->(cfop, **options) { cfop_issues(cfop, emit: {"IE" => nil}, ide: production.merge(options.fetch(:ide, {}))).grep(/rej\. 159/) }

      expect(no_ie.call("5102")).to contain_exactly(a_string_matching(/5102 .* without state registration.*rej\. 159/))
      expect(no_ie.call("5551")).to eq([])
      expect(no_ie.call("5202", ide: {"finNFe" => "4"})).to eq([])
    end

    it "asks it from the days NT 2026.007 v1.11 gives: 26/10/2026 in homologação, 16/11/2026 in production (I08-191)" do
      at = ->(environment, day) { cfop_issues("5102", emit: {"IE" => nil}, ide: {"tpAmb" => environment, "dhEmi" => day}).grep(/rej\. 159/) }

      expect(at.call("1", "2026-11-15T23:59:00-03:00")).to eq([])
      expect(at.call("2", "2026-10-25T23:59:00-03:00")).to eq([])
      expect(at.call("2", "2026-10-26T00:00:00-03:00").size).to eq(1)
    end

    describe "the DIFAL group (NA01-20)" do
      let(:sale) { {ide: {"idDest" => "2", "indFinal" => "1"}, dest: {"indIEDest" => "9"}} }

      def difal_issues(cfop = "6108", ide: {}, **options)
        cfop_issues(cfop, **sale, **options, ide: sale[:ide].merge(ide)).grep(/rej\. 694/)
      end

      it "is required on an interstate sale to a non-contributor final consumer" do
        expect(difal_issues).to eq(["det[1]/imposto/ICMSUFDest: required on 6108 (Venda de mercadoria adquirida ou recebida de terceiros…) " \
                                    "to a final consumer in another state who isn't an ICMS taxpayer (DIFAL); give i.icms_destination " \
                                    "with the destination state's rates (rej. 694)"])
        expect(difal_issues(imposto: {"ICMS" => {"ICMS00" => {"CST" => "00"}}, "ICMSUFDest" => {}})).to eq([])
      end

      it "is not required where the rule makes an exception" do
        expect(difal_issues("6916")).to eq([])                                                          # retorno
        expect(difal_issues("6915")).to eq([])                                                          # remessa
        expect(difal_issues("6552")).to eq([])
        expect(difal_issues(imposto: {"ICMS" => {"ICMSPart" => {"CST" => "10"}}})).to eq([])
        expect(difal_issues(imposto: {"ICMS" => {"ICMS40" => {"CST" => "40"}}})).to eq([])
        expect(difal_issues(emit: {"CRT" => "1"})).to eq([])
        expect(difal_issues(ide: {"finNFe" => "2"})).to eq([])
        expect(difal_issues(inf: {"entrega" => {"UF" => "SP"}})).to eq([])
        expect(difal_issues(prod: {"comb" => {"cProdANP" => "320102001"}})).to eq([])
        expect(difal_issues(prod: {"comb" => {"cProdANP" => "820101001"}})).not_to eq([])
      end

      it "is not required on a return of a note issued before 2016" do
        old = "35151111444777000161550010000000011000000010"
        recent = "35261011444777000161550010000000011000000010"
        expect(difal_issues("6202", ide: {"finNFe" => "4", "NFref" => [{"refNFe" => old}]})).to eq([])
        expect(difal_issues("6202", ide: {"finNFe" => "4", "NFref" => [{"refNFe" => recent}]})).not_to eq([])
        expect(difal_issues("6202", ide: {"finNFe" => "4"}, extra: {"DFeReferenciado" => {"chaveAcesso" => old}})).to eq([])
        expect(difal_issues("6202", ide: {"finNFe" => "4"}, extra: {"DFeReferenciado" => {"chaveAcesso" => recent}})).not_to eq([])
      end

      it "is not required in production before 01/07/2016" do
        expect(difal_issues(ide: {"tpAmb" => "1", "dhEmi" => "2016-06-30T10:00:00-03:00"})).to eq([])
        expect(difal_issues(ide: {"tpAmb" => "1", "dhEmi" => "2016-07-01T10:00:00-03:00"})).not_to eq([])
        expect(difal_issues(ide: {"tpAmb" => "2", "dhEmi" => "2016-06-30T10:00:00-03:00"})).not_to eq([])
      end
    end

    it "requires the fuel group on a fuel CFOP (LA01-20)" do
      expect(cfop_issues("5656")).to contain_exactly(a_string_matching(%r{det\[1\]/prod/comb: required on 5656 .*a fuel CFOP \(rej\. 660\)}))
      expect(cfop_issues("5656", prod: {"comb" => {"cProdANP" => "320102001"}})).to eq([])
    end

    it "requires a transport CFOP on the retained transport ICMS (X16-10)" do
      expect(cfop_issues("5102", inf: {"transp" => {"retTransp" => {"CFOP" => "5102"}}}))
        .to contain_exactly(a_string_matching(%r{transp/retTransp/CFOP: 5102 .* is not a transport CFOP.*rej\. 722}))
      expect(cfop_issues("5102", inf: {"transp" => {"retTransp" => {"CFOP" => "5352"}}})).to eq([])
    end
  end

  it "requires a payment method of the table, in force on the issue date" do
    issues = ->(kind, issued = "2026-09-29T10:00:00-03:00") {
      described_class.new({"ide" => {"dhEmi" => issued}, "pag" => {"detPag" => [{"tPag" => kind, "vPag" => "0.00"}]}}).issues.grep(%r{\Apag/})
    }

    expect(issues.call("06")).to eq(["pag/detPag[1]/tPag: 06 is not a payment method (see DfeRb::Nfe::Tables.payment_methods)"])
    expect(issues.call("23", "2026-05-03T23:00:00-03:00"))
      .to eq(["pag/detPag[1]/tPag: 23 (Pagamento Instantâneo (PIX) - Automático) is only accepted from 04/05/2026"])
    expect(issues.call("23") + issues.call("01") + issues.call("90")).to eq([])
  end

  describe "what a note references (NT 2026.002 v1.11)" do
    let(:nfce_key) { "50261111444777000161650010000000011000000019" }
    let(:sat_key) { "35261111444777000161590010000000011000000010" }
    let(:nfe_key) { "50261111444777000161550010000000011000000014" }

    def reference_issues(references = [], ide: {}, item: {}, cfop: "5102")
      tree = {"ide" => {"mod" => "55", "tpNF" => "1", "finNFe" => "1", "tpAmb" => "1", "dhEmi" => "2026-12-14T09:00:00-03:00",
                        "NFref" => references}.merge(ide),
              "det" => [{"prod" => {"CFOP" => cfop}}.merge(item)]}
      described_class.new(tree).issues.grep(/rej\. (679|375|681|682|924)\)/)
    end

    it "bars an exit note from referencing an NFC-e or a CF-e SAT, but for a complement or a return (BA02-35)" do
      expect(reference_issues([{"refNFe" => nfce_key}, {"refNFe" => sat_key}, {"refNFe" => nfe_key}])).to eq([
        "ide/NFref[1]/refNFe: an exit note can't reference an NFC-e (modelo 65), unless it complements or returns it (finNFe 2 or 4) (RV BA02-35, rej. 679)",
        "ide/NFref[2]/refNFe: an exit note can't reference a CF-e SAT (modelo 59), unless it complements or returns it (finNFe 2 or 4) (RV BA02-35, rej. 679)"
      ])
      expect(reference_issues([{"refNFe" => nfce_key}], ide: {"finNFe" => "2"})).to eq([])
      expect(reference_issues([{"refNFe" => nfce_key}], ide: {"finNFe" => "4"})).to eq([])
      expect(reference_issues([{"refNFe" => nfce_key}], ide: {"tpNF" => "0"})).to eq([])
    end

    it "bars the same on an item's referenced document, but for a debit note of types 03 and 04 (VC02-40)" do
      item = {"DFeReferenciado" => {"chaveAcesso" => nfce_key}}

      expect(reference_issues(item: item)).to contain_exactly(a_string_matching(
        %r{\Adet\[1\]/DFeReferenciado/chaveAcesso: an exit note's item can't reference an NFC-e \(modelo 65\).*\(RV VC02-40, rej\. 679\)\z}
      ))
      expect(reference_issues(item: item, ide: {"finNFe" => "6", "tpNFDebito" => "04"})).to eq([])
      expect(reference_issues(item: item, ide: {"finNFe" => "6", "tpNFDebito" => "01"})).not_to eq([])
    end

    it "bars a note for a sale a cupom fiscal covered from referencing an NFC-e (I08-180)" do
      expect(reference_issues([{"refNFe" => nfce_key}], ide: {"finNFe" => "2"}, cfop: "5929"))
        .to eq(["det[1]/prod/CFOP: a note for a sale a cupom fiscal covered (5929) can't reference an NFC-e (RV I08-180, rej. 375)"])
      expect(reference_issues([{"refNFe" => nfe_key}], cfop: "6929")).to eq([])
    end

    it "applies them from 14/12/2026 in production and 01/09/2026 in homologação, as v1.11 dates them" do
      references = [{"refNFe" => nfce_key}]

      expect(reference_issues(references, ide: {"dhEmi" => "2026-12-13T23:59:00-03:00"})).to eq([])
      expect(reference_issues(references, ide: {"tpAmb" => "2", "dhEmi" => "2026-09-01T00:00:00-03:00"}).size).to eq(1)
      expect(reference_issues(references, ide: {"tpAmb" => "2", "dhEmi" => "2026-08-31T23:59:00-03:00"})).to eq([])
    end

    it "bars a paper note, a rural producer's paper note and a cupom fiscal from 05/10/2026 (BA03-10, BA10-10, BA20-30)" do
      references = [{"refNF" => {"cUF" => "50", "AAMM" => "2609", "CNPJ" => "11444777000161", "mod" => "01", "serie" => "1", "nNF" => "1"}},
        {"refNFP" => {"cUF" => "50", "AAMM" => "2609", "CPF" => "52998224725", "IE" => "ISENTO", "mod" => "04", "serie" => "1", "nNF" => "1"}},
        {"refECF" => {"mod" => "2D", "nECF" => "1", "nCOO" => "1"}}]

      expect(reference_issues(references, ide: {"dhEmi" => "2026-10-05T08:00:00-03:00"})).to eq([
        "ide/NFref[1]/refNF: an NF-e can't reference a paper note, modelo 1 or 2 (RV BA03-10, rej. 681)",
        "ide/NFref[2]/refNFP: an NF-e can't reference a rural producer's paper note (RV BA10-10, rej. 682)",
        "ide/NFref[3]/refECF: an NF-e can't reference a cupom fiscal (RV BA20-30, rej. 924)"
      ])
      expect(reference_issues(references, ide: {"dhEmi" => "2026-10-04T08:00:00-03:00"})).to eq([])
    end
  end
end
