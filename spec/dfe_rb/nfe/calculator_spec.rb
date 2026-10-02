RSpec.describe DfeRb::Nfe::Calculator do
  let(:context) do
    described_class::Context.new(origin_state: "SP", destination_state: "SP", destination: 1, year: 2026, purchase_reduction: nil, purpose: 1)
  end

  def item(imposto, prod = {})
    {"prod" => {"vProd" => "100.00"}.merge(prod), "imposto" => imposto}
  end

  def calculate(imposto, prod = {}, with = context) = described_class.call(item(imposto, prod), with)["imposto"]

  def decimal(value) = value.is_a?(String) ? value : value&.to_s("F")

  describe "ICMS" do
    it "multiplies base and rate, rounding half up" do
      icms = calculate({"ICMS" => {"ICMS00" => {"vBC" => "100.05", "pICMS" => "5.00", "pFCP" => "2.00"}}})["ICMS"]["ICMS00"]

      expect(decimal(icms["vICMS"])).to eq("5.0")   # 5.0025
      expect(decimal(icms["vFCP"])).to eq("2.0")    # 2.001
      expect(decimal(calculate({"ICMS" => {"ICMS00" => {"vBC" => "0.10", "pICMS" => "5.00"}}})["ICMS"]["ICMS00"]["vICMS"])).to eq("0.01")
    end

    it "keeps values given explicitly" do
      icms = calculate({"ICMS" => {"ICMS00" => {"vBC" => "100.00", "pICMS" => "18.00", "vICMS" => "17.99"}}})["ICMS"]["ICMS00"]

      expect(icms["vICMS"]).to eq("17.99")
    end

    it "derives nothing when an input is missing" do
      icms = calculate({"ICMS" => {"ICMS00" => {"vBC" => "100.00"}}})["ICMS"]["ICMS00"]

      expect(icms).not_to have_key("vICMS")
    end

    it "uses the FCP base outside CST 00" do
      icms = calculate({"ICMS" => {"ICMS20" => {"vBC" => "80.00", "pICMS" => "18.00", "vBCFCP" => "80.00", "pFCP" => "2.00"}}})["ICMS"]["ICMS20"]

      expect([decimal(icms["vICMS"]), decimal(icms["vFCP"])]).to eq(%w[14.4 1.6])
    end

    it "splits the deferred ICMS of CST 51" do
      icms = calculate({"ICMS" => {"ICMS51" => {"vBC" => "100.00", "pICMS" => "18.00", "pDif" => "33.33"}}})["ICMS"]["ICMS51"]

      expect(%w[vICMSOp vICMSDif vICMS].map { |tag| decimal(icms[tag]) }).to eq(%w[18.0 6.0 12.0])
    end

    it "deducts the own ICMS from the ST tax, leaving the ST base to the issuer" do
      given = {"vBC" => "100.00", "pICMS" => "18.00", "modBCST" => "4", "pMVAST" => "40.00", "pICMSST" => "18.00"}
      icms = calculate({"ICMS" => {"ICMS10" => given.merge("vBCST" => "154.00")}})["ICMS"]["ICMS10"]

      # 154 x 18% - 18 = 9.72
      expect(decimal(icms["vICMSST"])).to eq("9.72")
      # The ST base composition (discounts, freight, MVA) is state law.
      expect(calculate({"ICMS" => {"ICMS10" => given}})["ICMS"]["ICMS10"]).not_to have_key("vBCST")
    end

    it "computes from the operands as the XML writes them" do
      icms = calculate({"ICMS" => {"ICMS00" => {"vBC" => "1000000.00", "pICMS" => "18.000049"}}})["ICMS"]["ICMS00"]

      expect(decimal(icms["vICMS"])).to eq("180000.0")
    end

    it "defaults the interstate rate on an interstate operation" do
      interstate = context.dup.tap { |c| c.destination = 2 }
      interstate.destination_state = "BA"
      domestic = calculate({"ICMS" => {"ICMS00" => {"orig" => 0, "vBC" => "100.00"}}}, {}, interstate)["ICMS"]["ICMS00"]
      imported = calculate({"ICMS" => {"ICMS00" => {"orig" => 1, "vBC" => "100.00"}}}, {}, interstate)["ICMS"]["ICMS00"]

      expect([decimal(domestic["pICMS"]), decimal(domestic["vICMS"])]).to eq(%w[7.0 7.0])
      expect(decimal(imported["pICMS"])).to eq("4.0")
    end

    it "leaves the rates fixed by law to the issuer outside a normal operation" do
      devolution = described_class::Context.new(origin_state: "BA", destination_state: "SP", destination: 2, year: 2026, purpose: 4)
      imposto = calculate({"ICMS" => {"ICMS00" => {"orig" => 0, "vBC" => "100.00"}},
                           "ICMSUFDest" => {"vBCUFDest" => "100.00", "pICMSUFDest" => "18.00"},
                           "IBSCBS" => {"cClassTrib" => "000001"}}, {}, devolution)

      expect(imposto["ICMS"]["ICMS00"]).not_to have_key("pICMS")
      expect(imposto["ICMSUFDest"].keys).not_to include("pICMSInter", "pICMSInterPart")
      expect(imposto["IBSCBS"]["gIBSCBS"]["gCBS"]).not_to have_key("pCBS")
    end
  end

  it "computes IPI, PIS and COFINS by rate or by quantity" do
    imposto = calculate(
      "IPI" => {"IPITrib" => {"qUnid" => "3.0000", "vUnid" => "1.5000"}},
      "PIS" => {"PISAliq" => {"vBC" => "100.00", "pPIS" => "1.65"}},
      "COFINS" => {"COFINSQtde" => {"qBCProd" => "10.0000", "vAliqProd" => "0.3000"}}
    )

    expect(decimal(imposto["IPI"]["IPITrib"]["vIPI"])).to eq("4.5")
    expect(decimal(imposto["PIS"]["PISAliq"]["vPIS"])).to eq("1.65")
    expect(decimal(imposto["COFINS"]["COFINSQtde"]["vCOFINS"])).to eq("3.0")
  end

  it "splits the DIFAL between the states with the partition of the year (NA11, NA13, NA15, NA17)" do
    interstate = described_class::Context.new(origin_state: "SP", destination_state: "BA", destination: 2, year: 2026, purpose: 1)
    difal = calculate({"ICMS" => {"ICMS00" => {"orig" => 0, "vBC" => "100.00", "pICMS" => "7.00"}},
                       "ICMSUFDest" => {"vBCUFDest" => "100.00", "pICMSUFDest" => "20.50", "vBCFCPUFDest" => "100.00", "pFCPUFDest" => "2.00"}},
      {}, interstate)["ICMSUFDest"]

    expect(%w[pICMSInter pICMSInterPart vFCPUFDest vICMSUFDest vICMSUFRemet].map { |tag| decimal(difal[tag]) })
      .to eq(%w[7.00 100.0 2.0 13.5 0.0])
  end

  it "computes the ad valorem selective tax" do
    expect(decimal(calculate({"IS" => {"vBCIS" => "100.00", "pIS" => "25.00"}})["IS"]["vIS"])).to eq("25.0")
  end

  describe "IBS and CBS" do
    def ibs_cbs(group, with = context)
      calculate({"PIS" => {"PISAliq" => {"vBC" => "100.00", "pPIS" => "1.65"}},
                 "COFINS" => {"COFINSAliq" => {"vBC" => "100.00", "pCOFINS" => "7.60"}},
                 "ICMS" => {"ICMS00" => {"vBC" => "100.00", "pICMS" => "18.00"}},
                 "IBSCBS" => group}, {}, with)["IBSCBS"]
    end

    it "takes the CST from the classification and fills the 2026 rates, base and amounts" do
      group = ibs_cbs({"cClassTrib" => "000001"})
      ibs = group["gIBSCBS"]

      expect(group["CST"]).to eq("000")
      # UB16-10: 100 - 1.65 - 7.60 - 18.00
      expect(decimal(ibs["vBC"])).to eq("72.75")
      expect([ibs["gIBSUF"]["pIBSUF"], ibs["gIBSMun"]["pIBSMun"], ibs["gCBS"]["pCBS"]].map { |rate| decimal(rate) }).to eq(%w[0.1 0.0 0.9])
      expect([ibs["gIBSUF"]["vIBSUF"], ibs["gIBSMun"]["vIBSMun"], ibs["vIBS"], ibs["gCBS"]["vCBS"]].map { |value| decimal(value) })
        .to eq(%w[0.07 0.0 0.07 0.65])
      expect(ibs["gIBSUF"]).not_to have_key("gRed")
    end

    it "applies the classification's rate reduction (UB28-10)" do
      ibs = ibs_cbs({"cClassTrib" => "200034", "gIBSCBS" => {"vBC" => "1000.00"}})["gIBSCBS"]

      expect(ibs["gCBS"]["gRed"].transform_values { |value| decimal(value) }).to eq("pRedAliq" => "60.0", "pAliqEfet" => "0.36")
      expect(decimal(ibs["gCBS"]["vCBS"])).to eq("3.6")
    end

    it "computes the effective rate with the government purchase reducer" do
      expect(described_class.effective_rate("10", "40", "5").to_s("F")).to eq("5.7")
      expect(described_class.effective_rate("0.9", "60", "3.33").to_s("F")).to eq("0.348")
    end

    it "takes deferral and returned tax out of each sphere's amount" do
      group = {"gIBSCBS" => {"vBC" => "1000.00", "gCBS" => {"pCBS" => "0.90", "gDif" => {"pDif" => "50.00"}, "gDevTrib" => {"vDevTrib" => "1.00"}}}}
      cbs = ibs_cbs(group)["gIBSCBS"]["gCBS"]

      expect([decimal(cbs["gDif"]["vDif"]), decimal(cbs["vCBS"])]).to eq(%w[4.5 3.5])
    end

    it "charges nothing in the main group of a classification taxed in gTribRegular (UB18-10, UB56-10)" do
      ibs = ibs_cbs({"cClassTrib" => "550001", "gIBSCBS" => {"vBC" => "1000.00"}})["gIBSCBS"]

      expect([ibs["gIBSUF"]["pIBSUF"], ibs["gCBS"]["pCBS"]].map { |rate| decimal(rate) }).to eq(%w[0.0 0.0])
      expect([ibs["gIBSUF"]["vIBSUF"], ibs["gCBS"]["vCBS"]].map { |value| decimal(value) }).to eq(%w[0.0 0.0])
    end

    it "computes no amount of a deferral CST until the deferral is given (UB22-20, UB59-10)" do
      ibs = ibs_cbs({"cClassTrib" => "510001", "gIBSCBS" => {"vBC" => "1000.00"}})["gIBSCBS"]

      expect(ibs["gIBSUF"]).not_to have_key("vIBSUF")
      expect(ibs["gCBS"]).not_to have_key("vCBS")
      expect(ibs).not_to have_key("vIBS")
    end

    it "leaves untaxed and monophase classifications without gIBSCBS" do
      expect(ibs_cbs({"cClassTrib" => "410001"})).not_to have_key("gIBSCBS")
    end

    it "leaves the CBS rate empty in a year it is not law yet" do
      later = context.dup.tap { |c| c.year = 2027 }

      expect(ibs_cbs({"cClassTrib" => "000001"}, later)["gIBSCBS"]["gCBS"]).not_to have_key("pCBS")
    end
  end
end
