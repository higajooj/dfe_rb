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

  describe "CFOP rules" do
    # Issues of a note with one item on `cfop`, from a regime normal issuer with IE in SP.
    def cfop_issues(cfop, ide: {}, emit: {}, dest: {}, prod: {}, imposto: {"ICMS" => {"ICMS00" => {"CST" => "00"}}}, inf: {})
      tree = {"ide" => {"finNFe" => "1", "tpNF" => "1", "dhEmi" => "2026-09-29T10:00:00-03:00"}.merge(ide),
              "emit" => {"IE" => "111111111111", "CRT" => "3", "enderEmit" => {"UF" => "SP"}}.merge(emit),
              "dest" => {"indIEDest" => "1", "enderDest" => {"UF" => "RJ"}}.merge(dest),
              "det" => [{"prod" => {"CFOP" => cfop, "NCM" => "84713012"}.merge(prod), "imposto" => imposto}]}.merge(inf)
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

    it "accepts 1949/2949 on any return and 5949/6949 on a natural gas return (I08-140)" do
      expect(cfop_issues("1949", ide: {"finNFe" => "4"})).to eq([])
      expect(cfop_issues("1949", ide: {"finNFe" => "5", "tpNFCredito" => "03"})).to include(a_string_matching(/rej\. 327/))
      expect(cfop_issues("5949", ide: {"finNFe" => "4"}, prod: {"NCM" => "27112100"})).to eq([])
      expect(cfop_issues("5949", ide: {"finNFe" => "4"})).to include(a_string_matching(/rej\. 327/))
    end

    it "limits a MEI's returns to six CFOPs (I08-141)" do
      expect(cfop_issues("5202", ide: {"finNFe" => "4"}, emit: {"CRT" => "4"})).to eq([])
      expect(cfop_issues("5411", ide: {"finNFe" => "4"}, emit: {"CRT" => "4"}))
        .to contain_exactly(a_string_matching(/5411 .* can't be used on a return issued by a MEI; use 1202, .*6202 \(rej\. 1179\)/))
    end

    it "limits an issuer without IE to the CFOPs marked indExcIBSCBS, except on returns (I08-191)" do
      expect(cfop_issues("5102", emit: {"IE" => nil})).to contain_exactly(a_string_matching(/5102 .* without state registration.*rej\. 159/))
      expect(cfop_issues("5551", emit: {"IE" => nil})).to eq([])
      expect(cfop_issues("5202", emit: {"IE" => nil}, ide: {"finNFe" => "4"})).to eq([])
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
end
