RSpec.describe DfeRb::Nfe::Validator do
  # Issues about the first item of a note with only `ide` and that item.
  def item_issues(imposto, ide: {}, extra: {})
    prod = {"qCom" => "1", "vUnCom" => "100.00", "qTrib" => "1", "vUnTrib" => "100.00", "vProd" => "100.00"}
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

  it "requires gDif where the CST calls for deferral and refuses it elsewhere (UB59-10, UB59-20)" do
    deferred = item_issues({"IBSCBS" => {"cClassTrib" => "510001", "gIBSCBS" => {"vBC" => "100.00", "gCBS" => {"pCBS" => "0.90"}}}})
    regular = item_issues({"IBSCBS" => {"cClassTrib" => "000001",
                                        "gIBSCBS" => {"vBC" => "100.00", "gCBS" => {"pCBS" => "0.90", "gDif" => {"pDif" => "10.00", "vDif" => "0.09"}, "vCBS" => "0.81"}}}})

    expect(deferred).to eq(["det[1]/imposto/IBSCBS/gIBSCBS/gCBS/gDif: required for CST 510 (rej. 1061)"])
    expect(regular).to eq(["det[1]/imposto/IBSCBS/gIBSCBS/gCBS/gDif: not allowed for CST 000 (rej. 1090)"])
  end
end
