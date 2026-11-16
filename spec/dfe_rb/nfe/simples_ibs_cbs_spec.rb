# NT 2026.005 v1.00: the IBS and the CBS of the Simples Nacional (tpRegimeIBSCBS, cAtivSN, gTribSN
# and its totals W59h to W59j) and event 412140.
RSpec.describe "NT 2026.005 v1.00" do
  let(:client) { nfe_client(NfeHelpers::FakeTransport.new) }
  let(:ns) { {"nfe" => NfeHelpers::NFE_NS} }

  def doc(invoice) = Nokogiri::XML(invoice.to_xml)

  def text(document, path) = document.at_xpath(path, ns)&.text

  # An invoice of 2027 (the Simples Nacional's IBS and CBS start then) from an issuer of the given regime.
  def invoice_for(regime, ibs_cbs_regime: nil, activity: "01", at: "2027-01-04T10:00:00-03:00", **ibs_cbs)
    client.build_invoice do |nfe|
      nfe.number 77
      nfe.issued_at at
      nfe.nature_of_operation "Venda"
      issuer = {tax_id: "11444777000161", name: "EMPRESA LTDA", state_registration: "111111111111", tax_regime: regime,
                address: {street: "Rua A", number: "100", district: "Centro", city_code: "3550308", city: "Sao Paulo", state: "SP", zip: "01001000"}}
      issuer[:ibs_cbs_regime] = ibs_cbs_regime if ibs_cbs_regime
      nfe.issuer(**issuer)
      nfe.recipient cnpj: "11222333000181", name: "CLIENTE", state_registration: "123456789",
        address: {street: "Rua B", number: "1", district: "Centro", city_code: "3550308", city: "Sao Paulo", state: "SP", zip: "01001000"}
      2.times do |index|
        nfe.item do |i|
          i.code "A#{index}"
          i.description "Item"
          i.ncm "84713012"
          i.cfop "5102"
          i.unit "UN"
          i.quantity 1
          i.unit_price "100.00"
          i.icms csosn: "102", origin: :domestic
          i.pis cst: "08"
          i.cofins cst: "08"
          i.simples_activity activity if activity
          i.ibs_cbs(cst: "000", class_code: "000001", **ibs_cbs)
        end
      end
      nfe.payment :pix
    end
  end

  def issues_of(invoice) = invoice.issues.grep(/IBSCBS|gTribSN|cAtivSN|tpRegimeIBSCBS|vIBSSN|vCBSSN|gIBSCBS/)

  let(:simples_ibs) { {simples_ibs: {rate: "1.00", amount: "1.00"}, simples_cbs: {rate: "0.50", amount: "0.50"}} }
  let(:regular_taxes) do
    {ibs_uf: {rate: "0.05", amount: "0.05"}, ibs_municipal: {rate: "0.05", amount: "0.05"}, cbs: {rate: "8.70", amount: "8.70"}, base: "100.00"}
  end

  describe "a CRT 1 issuer under the regular regime of the IBS and the CBS (tpRegimeIBSCBS 1)" do
    it "writes the issuer's regime, each item's activity and the regular groups, with the usual totals" do
      invoice = invoice_for(:simples, ibs_cbs_regime: 1, **regular_taxes)
      document = doc(invoice)

      expect(invoice.issues).to eq([])
      expect(text(document, "//nfe:emit/nfe:tpRegimeIBSCBS")).to eq("1")
      expect(text(document, "//nfe:det[1]/nfe:prod/nfe:cAtivSN")).to eq("01")
      expect(document.at_xpath("//nfe:det[1]//nfe:gTribSN", ns)).to be_nil
      expect(text(document, "//nfe:total/nfe:IBSCBSTot/nfe:gIBS/nfe:vIBS")).to eq("0.20")
      expect(document.at_xpath("//nfe:IBSCBSTot/nfe:gTribSN", ns)).to be_nil
      expect(DfeRb::Nfe::Schemas.nfe_issues(invoice.to_xml)).to eq([])
    end

    it "bars gTribSN, which the regular regime doesn't carry" do
      invoice = invoice_for(:simples, ibs_cbs_regime: 1, **regular_taxes, **simples_ibs)

      expect(issues_of(invoice)).to include("det[1]/imposto/IBSCBS/gTribSN: not informed with this regime (NT 2026.005 §2.3)")
    end

    it "fills the rates and the base the law fixes, as for a regime normal issuer" do
      document = doc(invoice_for(:simples, ibs_cbs_regime: 1, base: nil, cbs: {rate: "8.70"}))

      expect(text(document, "//nfe:det[1]//nfe:gIBSCBS/nfe:vBC")).to eq("100.00")
      expect(text(document, "//nfe:det[1]//nfe:gIBSUF/nfe:pIBSUF")).to eq("0.05")
    end
  end

  describe "a CRT 1 issuer without the regular regime" do
    it "carries gTribSN with gIBSSN and gCBSSN and no gIBSCBS, and the totals W59h to W59j as their sums" do
      invoice = invoice_for(:simples, **simples_ibs)
      document = doc(invoice)

      expect(invoice.issues).to eq([])
      expect(document.at_xpath("//nfe:emit/nfe:tpRegimeIBSCBS", ns)).to be_nil
      expect(document.at_xpath("//nfe:det[1]//nfe:gIBSCBS", ns)).to be_nil
      expect(text(document, "//nfe:det[1]//nfe:gTribSN/nfe:gIBSSN/nfe:pIBSSN")).to eq("1.00")
      expect(text(document, "//nfe:det[1]//nfe:gTribSN/nfe:gCBSSN/nfe:vCBSSN")).to eq("0.50")
      expect(text(document, "//nfe:total/nfe:IBSCBSTot/nfe:gTribSN/nfe:vIBSSN")).to eq("2.00")
      expect(text(document, "//nfe:total/nfe:IBSCBSTot/nfe:gTribSN/nfe:vCBSSN")).to eq("1.00")
      expect(DfeRb::Nfe::Schemas.nfe_issues(invoice.to_xml)).to eq([])
    end

    it "doesn't make up a gIBSCBS for an item taxed by its classification" do
      document = doc(invoice_for(:simples, **simples_ibs))

      expect(document.xpath("//nfe:gIBSCBS", ns)).to be_empty
    end

    it "bars a gIBSCBS" do
      invoice = invoice_for(:simples, **regular_taxes, **simples_ibs)

      expect(issues_of(invoice)).to include("det[1]/imposto/IBSCBS/gIBSCBS: not informed by a Simples Nacional issuer without the regular regime of the IBS and the CBS (NT 2026.005 §2.3)")
    end

    it "flags what the totals W59h-10, W59h-20, W59i-10 and W59j-10 ask" do
      tree = lambda do |total, groups = [{"gIBSSN" => {"pIBSSN" => "1.00", "vIBSSN" => "1.00"}, "gCBSSN" => {"pCBSSN" => "0.50", "vCBSSN" => "0.50"}}]|
        items = groups.map { |group| {"prod" => {"CFOP" => "5102"}, "imposto" => {"IBSCBS" => {"gTribSN" => group}.compact}} }
        ide = {"finNFe" => "1", "tpAmb" => "1", "dhEmi" => "2027-01-04T10:00:00-03:00"}
        DfeRb::Nfe::Validator.new({"ide" => ide, "emit" => {"CRT" => "1"}, "det" => items, "total" => {"IBSCBSTot" => total}}).issues.grep(%r{\Atotal/IBSCBSTot})
      end

      expect(tree.call({"vBCIBSCBS" => "0.00"})).to eq(["total/IBSCBSTot/gTribSN: required when an item carries gTribSN (RV W59h-10, rej. 1275)"])
      expect(tree.call({"vBCIBSCBS" => "0.00", "gTribSN" => {"vIBSSN" => "1.00", "vCBSSN" => "0.50"}}, [])).to eq(["total/IBSCBSTot/gTribSN: no item carries gTribSN (RV W59h-20, rej. 1276)"])
      expect(tree.call({"gTribSN" => {"vIBSSN" => "1.00", "vCBSSN" => "0.50"}})).to eq([])
      expect(tree.call({"gTribSN" => {"vIBSSN" => "1.50", "vCBSSN" => "0.50"}}))
        .to eq(["total/IBSCBSTot/gTribSN/vIBSSN: 1.50 differs from the sum of the items' vIBSSN (1.00) (rej. 1277)"])
      expect(tree.call({"gTribSN" => {"vIBSSN" => "1.00", "vCBSSN" => "0.40"}}))
        .to eq(["total/IBSCBSTot/gTribSN/vCBSSN: 0.40 differs from the sum of the items' vCBSSN (0.50) (rej. 1284)"])
    end
  end

  describe "a CRT 2 issuer without the regular regime (excess of the sublimit)" do
    it "carries gIBSCBS with the CBS at zero, and gTribSN with gCBSSN only" do
      invoice = invoice_for(:simples_excess, ibs_uf: {rate: "0.05", amount: "0.05"}, ibs_municipal: {rate: "0.05", amount: "0.05"},
        simples_cbs: {rate: "0.50", amount: "0.50"})
      document = doc(invoice)

      expect(invoice.issues).to eq([])
      expect(text(document, "//nfe:det[1]//nfe:gIBSCBS/nfe:gCBS/nfe:pCBS")).to eq("0.00")
      expect(text(document, "//nfe:det[1]//nfe:gIBSCBS/nfe:gCBS/nfe:vCBS")).to eq("0.00")
      expect(document.at_xpath("//nfe:det[1]//nfe:gIBSSN", ns)).to be_nil
      expect(text(document, "//nfe:total/nfe:IBSCBSTot/nfe:gTribSN/nfe:vIBSSN")).to eq("0.00")
      expect(text(document, "//nfe:total/nfe:IBSCBSTot/nfe:gTribSN/nfe:vCBSSN")).to eq("1.00")
      expect(DfeRb::Nfe::Schemas.nfe_issues(invoice.to_xml)).to eq([])
    end

    it "bars gIBSSN and a CBS that isn't zero isn't held to the law's rate" do
      invoice = invoice_for(:simples_excess, **regular_taxes.merge(cbs: {rate: "0", amount: "0"}), **simples_ibs)

      expect(issues_of(invoice)).to eq(["det[1]/imposto/IBSCBS/gTribSN/gIBSSN: not informed with this regime (NT 2026.005 §2.3)",
        "det[2]/imposto/IBSCBS/gTribSN/gIBSSN: not informed with this regime (NT 2026.005 §2.3)"])
    end
  end

  describe "a regime normal issuer whose option for the Simples Nacional is pending (CRT 3)" do
    it "gives tpRegimeIBSCBS 2: gIBSCBS and gTribSN with both groups" do
      invoice = invoice_for(:normal, ibs_cbs_regime: 2, **regular_taxes, **simples_ibs)

      expect(issues_of(invoice)).to eq([])
      expect(text(doc(invoice), "//nfe:emit/nfe:tpRegimeIBSCBS")).to eq("2")
    end

    it "gives 3: gTribSN with gCBSSN only, and 4: none" do
      expect(issues_of(invoice_for(:normal, ibs_cbs_regime: 3, **regular_taxes, simples_cbs: {rate: "0.50", amount: "0.50"}))).to eq([])
      expect(issues_of(invoice_for(:normal, ibs_cbs_regime: 3, **regular_taxes, **simples_ibs)))
        .to include("det[1]/imposto/IBSCBS/gTribSN/gIBSSN: not informed with this regime (NT 2026.005 §2.3)")
      expect(issues_of(invoice_for(:normal, ibs_cbs_regime: 4, **regular_taxes))).to eq([])
      expect(issues_of(invoice_for(:normal, ibs_cbs_regime: 4, **regular_taxes, **simples_ibs)))
        .to include("det[1]/imposto/IBSCBS/gTribSN: not informed with this regime (NT 2026.005 §2.3)")
    end
  end

  describe "tpRegimeIBSCBS and cAtivSN" do
    it "takes tpRegimeIBSCBS only where the NT names it (§2.1)" do
      expect(issues_of(invoice_for(:simples, ibs_cbs_regime: 2, **regular_taxes)))
        .to include(a_string_matching(%r{\Aemit/tpRegimeIBSCBS: tpRegimeIBSCBS 2 is not one of CRT 1}))
      expect(issues_of(invoice_for(:normal, ibs_cbs_regime: 1, **regular_taxes)))
        .to include(a_string_matching(%r{\Aemit/tpRegimeIBSCBS: tpRegimeIBSCBS 1 is not one of CRT 3}))
    end

    it "takes cAtivSN only from an optante or one whose option is pending (§2.2)" do
      message = a_string_matching(%r{\Adet\[1\]/prod/cAtivSN: only a Simples Nacional issuer})

      expect(issues_of(invoice_for(:normal, **regular_taxes))).to include(message)
      expect(issues_of(invoice_for(:normal, activity: nil, **regular_taxes))).to eq([])
      expect(issues_of(invoice_for(:simples, ibs_cbs_regime: 1, **regular_taxes))).not_to include(message)
    end

    it "applies from 14/12/2026 in production and 26/10/2026 in homologação, by dhEmi" do
      stale = invoice_for(:normal, at: "2026-10-25T10:00:00-03:00", **regular_taxes)
      tree = ->(env, at) { {"ide" => {"finNFe" => "1", "tpAmb" => env, "dhEmi" => at}, "emit" => {"CRT" => "4"}, "det" => [{"prod" => {}, "imposto" => {"IBSCBS" => {}}}]} }
      mei = ->(env, at) { DfeRb::Nfe::Validator.new(tree.call(env, at)).issues.grep(/MEI/) }

      expect(stale.issues.grep(/cAtivSN|tpRegimeIBSCBS|MEI/)).to eq([])
      expect(mei.call("1", "2026-12-13T23:59:00-03:00")).to eq([])
      expect(mei.call("1", "2026-12-14T00:00:00-03:00").size).to eq(1)
      expect(mei.call("2", "2026-10-26T00:00:00-03:00").size).to eq(1)
    end
  end

  describe "a MEI (CRT 4)" do
    it "doesn't inform the IBSCBS group, on any item" do
      invoice = invoice_for(:mei, activity: nil, base: nil, cbs: {rate: "8.70"})

      expect(issues_of(invoice)).to eq(["det[1]/imposto/IBSCBS: a MEI (CRT 4) doesn't inform the IBS/CBS group (NT 2026.005 §2.3)",
        "det[2]/imposto/IBSCBS: a MEI (CRT 4) doesn't inform the IBS/CBS group (NT 2026.005 §2.3)"])
      expect { invoice.to_xml }.to raise_error(DfeRb::ValidationError, /a MEI \(CRT 4\) doesn't inform the IBS\/CBS group/)
    end

    it "has no tpRegimeIBSCBS either" do
      expect(issues_of(invoice_for(:mei, ibs_cbs_regime: 1, activity: nil, base: nil, cbs: {rate: "8.70"})))
        .to include("emit/tpRegimeIBSCBS: a MEI (CRT 4) has no tpRegimeIBSCBS (NT 2026.005 §2.1)")
    end
  end

  describe "a return, whose IBSCBS mirrors the supply (§2.4)" do
    it "isn't held to the regime's groups, which the supply may have carried under another" do
      tree = {"ide" => {"finNFe" => "4", "tpAmb" => "1", "dhEmi" => "2027-01-04T10:00:00-03:00"}, "emit" => {"CRT" => "1"},
              "det" => [{"prod" => {"CFOP" => "1202"}, "imposto" => {"IBSCBS" => {"gIBSCBS" => {"vBC" => "100.00"}}}}]}

      expect(DfeRb::Nfe::Validator.new(tree).issues.grep(/gIBSCBS: not informed/)).to eq([])
    end
  end

  describe "the Simples Nacional totals of the gem" do
    it "adds nothing for an item without gIBSSN, and writes none when no item has gTribSN" do
      expect(DfeRb::Nfe::Totals.ibs_cbs_total([{"imposto" => {"IBSCBS" => {"gTribSN" => {"gCBSSN" => {"vCBSSN" => "0.50"}}}}}]))
        .to include("gTribSN" => {"vIBSSN" => 0, "vCBSSN" => BigDecimal("0.5")})
      expect(DfeRb::Nfe::Totals.ibs_cbs_total([{"imposto" => {"IBSCBS" => {}}}])).not_to have_key("gTribSN")
    end
  end

  describe "event 412140, Tributação do Simples Nacional" do
    let(:detail) do
      %(<detEvento xmlns="#{NfeHelpers::NFE_NS}" versao="1.00"><descEvento>Tributação do Simples Nacional</descEvento>) +
        %(<cOrgaoAutor>35</cOrgaoAutor><tpAutor>5</tpAutor><verAplic>RFB_1.0</verAplic>) +
        %(<gTribItemSN nItem="1"><vRBSNitem>100.00</vRBSNitem><tpRBSN>1</tpRBSN><pIBSSN>1.0000</pIBSSN><vIBSSN>1.00</vIBSSN>) +
        %(<pCBSSN>0.5000</pCBSSN><vCBSSN>0.50</vCBSSN></gTribItemSN>) +
        %(<gTotalSN><vRBSNtot>100.00</vRBSNtot><vIBSSNtot>1.00</vIBSSNtot><vCBSSNtot>0.50</vCBSSNtot></gTotalSN></detEvento>)
    end

    it "checks the detail of an event received from the distribution against its schema" do
      expect(DfeRb::Nfe::Events.detail_issues("412140", detail)).to eq([])
      expect(DfeRb::Nfe::Events.detail_issues("412140", detail.sub("<tpAutor>5</tpAutor>", "<tpAutor>1</tpAutor>"))).not_to eq([])
      expect(DfeRb::Nfe::Events.detail_issues(412140, detail.sub("<tpRBSN>1</tpRBSN>", "<tpRBSN>7</tpRBSN>"))).not_to eq([])
    end

    it "knows no other event" do
      expect { DfeRb::Nfe::Events.detail_issues("999999", detail) }.to raise_error(ArgumentError, /no detail schema for event 999999/)
    end
  end
end
