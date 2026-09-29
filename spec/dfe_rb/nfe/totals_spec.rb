RSpec.describe DfeRb::Nfe::Totals do
  def item(value, imposto = {}, prod = {})
    {"prod" => {"vProd" => value, "indTot" => 1}.merge(prod), "imposto" => imposto}
  end

  def total(items) = described_class.icms_total(items).transform_values { |value| value.to_s("F") }

  it "adds the retained monophase ICMS to vNF and totals every monophase field (NT 2023.001)" do
    monophase = item("20.00", "ICMS" => {"ICMS15" => {"qBCMono" => "10.0000", "vICMSMono" => "1.00",
                                                      "qBCMonoReten" => "10.0000", "vICMSMonoReten" => "2.00"}})
    earlier = item("5.00", "ICMS" => {"ICMS61" => {"qBCMonoRet" => "3.0000", "vICMSMonoRet" => "0.50"}})

    expect(total([monophase, earlier])).to include("vNF" => "27.0", "qBCMono" => "10.0", "vICMSMono" => "1.0",
      "qBCMonoReten" => "10.0", "vICMSMonoReten" => "2.0", "qBCMonoRet" => "3.0", "vICMSMonoRet" => "0.5")
  end

  it "leaves the monophase totals out when no item is monophase" do
    expect(total([item("20.00")]).keys.grep(/Mono/)).to be_empty
  end

  it "deducts only the exemptions each item flags as deducted" do
    deducted = item("20.00", "ICMS" => {"ICMS40" => {"vICMSDeson" => "1.00", "indDeduzDeson" => "1"}})
    kept = item("20.00", "ICMS" => {"ICMS40" => {"vICMSDeson" => "2.00", "indDeduzDeson" => "0"}})

    expect(total([deducted, kept])).to include("vICMSDeson" => "3.0", "vNF" => "39.0")
  end

  it "adds PIS-ST and COFINS-ST to vNF only when the item says so" do
    summed = item("10.00", "PISST" => {"vPIS" => "0.50", "indSomaPISST" => "1"}, "COFINSST" => {"vCOFINS" => "1.00", "indSomaCOFINSST" => "1"})
    apart = item("10.00", "PISST" => {"vPIS" => "0.50", "indSomaPISST" => "0"})

    expect(total([summed, apart])["vNF"]).to eq("21.5")
  end

  it "leaves ICMS-ST out of vNF on a direct sale of new vehicles (tpOp 2)" do
    vehicle = item("100.00", {"ICMS" => {"ICMS10" => {"vICMSST" => "10.00", "vFCPST" => "1.00"}}}, {"veicProd" => {"tpOp" => "2"}})

    expect(total([vehicle])).to include("vST" => "10.0", "vNF" => "100.0")
  end

  it "sums item values as the XML rounds them" do
    items = Array.new(4) { item("1.00", "PIS" => {"PISAliq" => {"vPIS" => "0.005"}}) }
    expect(total(items)["vPIS"]).to eq("0.04")
  end

  describe ".ibs_cbs_total" do
    it "is required as soon as any item carries IBSCBS, even without a calculation group" do
      exempt = item("10.00", "IBSCBS" => {"CST" => "410", "cClassTrib" => "410001"})

      expect(described_class.ibs_cbs_total([exempt])).to eq("vBCIBSCBS" => BigDecimal(0))
    end

    it "totals the monophase and credit reversal groups" do
      mono = item("10.00", "IBSCBS" => {
        "CST" => "620", "cClassTrib" => "620001",
        "gIBSCBSMono" => {"gIBSMonoAdRem" => {"gMonoPadrao" => {"vIBSMono" => "1.10"}, "gMonoReten" => {"vIBSMonoReten" => "0.20"}},
                          "gCBSMonoAdRem" => {"gMonoPadrao" => {"vCBSMono" => "2.30"}}},
        "gEstornoCred" => {"vIBSEstCred" => "0.40", "vCBSEstCred" => "0.60"}
      })

      totals = described_class.ibs_cbs_total([mono])
      expect(totals["gMono"].transform_values { |v| v.to_s("F") }).to eq("vIBSMono" => "1.1", "vCBSMono" => "2.3",
        "vIBSMonoReten" => "0.2", "vCBSMonoReten" => "0.0", "vIBSMonoRet" => "0.0", "vCBSMonoRet" => "0.0")
      expect(totals["gEstornoCred"].transform_values { |v| v.to_s("F") }).to eq("vIBSEstCred" => "0.4", "vCBSEstCred" => "0.6")
      expect(totals).not_to have_key("gIBS")
    end

    it "is nil when no item carries IBSCBS" do
      expect(described_class.ibs_cbs_total([item("10.00")])).to be_nil
    end
  end
end
