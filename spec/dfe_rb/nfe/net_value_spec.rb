# NT 2026.008 v1.01: the net value of an item and its total (I11b, I11c, W01a), the ICMS expected at
# the supply of an advance payment (NB01), the rules around them (B25-80, VB01-10, VB01-20) and the
# reading of vProd and vItem.
RSpec.describe "NT 2026.008 v1.01" do
  let(:client) { nfe_client(NfeHelpers::FakeTransport.new) }
  let(:ns) { {"nfe" => NfeHelpers::NFE_NS} }

  def doc(invoice) = Nokogiri::XML(invoice.to_xml)

  def text(document, path) = document.at_xpath(path, ns)&.text

  # Issues of a hand-written note: its ide, one item, and its total.
  def issues_of(ide: {}, prod: {}, imposto: {}, item: {}, total: nil, items: nil)
    prod = {"qCom" => "2", "vUnCom" => "10.00", "qTrib" => "2", "vUnTrib" => "10.00", "vProd" => "20.00"}.merge(prod)
    tree = {"ide" => {"finNFe" => "1", "mod" => "55", "tpAmb" => "1", "dhEmi" => "2026-12-14T10:00:00-03:00"}.merge(ide),
            "det" => items || [{"prod" => prod, "imposto" => imposto}.merge(item)]}
    tree["total"] = total if total
    DfeRb::Nfe::Validator.new(tree).issues.grep(%r{\A(det\[|total/vProdLiqTot)})
  end

  describe "writing the net value" do
    def net_invoice(net_unit_price: nil, net_amount: nil, net_total: nil)
      simples_invoice(client) do |nfe|
        nfe.issued_at "2026-12-14T10:00:00-03:00"
        nfe.item do |i|
          i.code "2"
          i.description "Outro produto"
          i.ncm "84713012"
          i.cfop "6102"
          i.unit "UN"
          i.quantity 3
          i.unit_price "10.00"
          i.icms csosn: "102", origin: :domestic
          i.pis cst: "07"
          i.cofins cst: "07"
          i.net_unit_price net_unit_price if net_unit_price
          i.net_amount net_amount if net_amount
        end
        nfe.totals net_total: net_total if net_total
      end
    end

    it "works out vProdLiq from the net unit price and totals them in vProdLiqTot, ahead of ICMSTot" do
      invoice = net_invoice(net_unit_price: "8.50")
      document = doc(invoice)

      expect(text(document, "//nfe:det[2]/nfe:prod/nfe:vUnComLiq").then { |value| BigDecimal(value) }).to eq(BigDecimal("8.5"))
      expect(text(document, "//nfe:det[2]/nfe:prod/nfe:vProdLiq")).to eq("25.50")
      expect(text(document, "//nfe:det[1]/nfe:prod/nfe:vProdLiq")).to be_nil
      expect(text(document, "//nfe:total/nfe:vProdLiqTot")).to eq("25.50")
      expect(document.at_xpath("//nfe:total/*[1]", ns).name).to eq("vProdLiqTot")
      expect(invoice.issues).to eq([])
      expect(DfeRb::Nfe::Schemas.nfe_issues(invoice.to_xml)).to eq([])
    end

    it "works out the net unit price from vProdLiq alone" do
      document = doc(net_invoice(net_amount: "25.50"))

      expect(text(document, "//nfe:det[2]/nfe:prod/nfe:vUnComLiq").then { |value| BigDecimal(value) }).to eq(BigDecimal("8.5"))
      expect(text(document, "//nfe:total/nfe:vProdLiqTot")).to eq("25.50")
    end

    it "sums the items that give a net value, to the cent" do
      invoice = simples_invoice(client) do |nfe|
        nfe.issued_at "2026-12-14T10:00:00-03:00"
        nfe.item do |i|
          i.code "3"
          i.description "Terceiro"
          i.ncm "84713012"
          i.cfop "6102"
          i.unit "UN"
          i.quantity "0.333"
          i.unit_price "10.00"
          i.net_unit_price "9.9999"
          i.icms csosn: "102", origin: :domestic
          i.pis cst: "07"
          i.cofins cst: "07"
        end
      end

      expect(text(doc(invoice), "//nfe:det[2]/nfe:prod/nfe:vProdLiq")).to eq("3.33")
      expect(text(doc(invoice), "//nfe:total/nfe:vProdLiqTot")).to eq("3.33")
    end

    it "invents nothing for an item that gives no net value, since the gem can't tell which taxes a price carries" do
      document = doc(simples_invoice(client))

      expect(document.xpath("//nfe:vUnComLiq | //nfe:vProdLiq | //nfe:vProdLiqTot", ns)).to be_empty
    end

    it "keeps a vProdLiqTot the caller gives, and flags it when it isn't their sum (W01a-20)" do
      invoice = net_invoice(net_unit_price: "8.50", net_total: "99.00")

      expect(invoice.issues).to include("total/vProdLiqTot: 99.00 differs from the sum of the items' vProdLiq (25.50) (rej. 1283)")
      expect { invoice.to_xml }.to raise_error(DfeRb::ValidationError, /vProdLiqTot: 99.00 differs/)
    end
  end

  describe "RV I11c-20, W01a-10, W01a-20" do
    let(:net) { {"vUnComLiq" => "9.00", "vProdLiq" => "18.00"} }

    it "accepts a net value that is the net unit price x the quantity, within a cent" do
      expect(issues_of(prod: net, total: {"vProdLiqTot" => "18.00"})).to eq([])
      expect(issues_of(prod: net.merge("vProdLiq" => "18.01"), total: {"vProdLiqTot" => "18.01"})).to eq([])
    end

    it "refuses one that differs on a normal note (I11c-20, rej. 1279), but not on a complement" do
      wrong = net.merge("vProdLiq" => "17.00")
      total = {"vProdLiqTot" => "17.00"}

      expect(issues_of(prod: wrong, total: total)).to eq(["det[1]/prod/vProdLiq: 17.00 differs from net unit price x quantity (18.00) (rej. 1279)"])
      expect(issues_of(prod: wrong, total: total, ide: {"finNFe" => "2"})).to eq([])
    end

    it "wants the total once an item gives vProdLiq (W01a-10, rej. 1282) and as their sum (W01a-20, rej. 1283)" do
      expect(issues_of(prod: net)).to eq(["total/vProdLiqTot: required when an item gives vProdLiq (RV W01a-10, rej. 1282)"])
      expect(issues_of(prod: net, total: {"vProdLiqTot" => "20.00"}))
        .to eq(["total/vProdLiqTot: 20.00 differs from the sum of the items' vProdLiq (18.00) (rej. 1283)"])
      expect(issues_of(total: {"vProdLiqTot" => "1.00"}))
        .to eq(["total/vProdLiqTot: 1.00 differs from the sum of the items' vProdLiq (0.00) (rej. 1283)"])
    end

    it "leaves an item without a net value alone (I11c-10 is not enforced yet)" do
      expect(issues_of).to eq([])
    end

    it "applies from 14/12/2026 in production and from 26/10/2026 in homologação, by dhEmi" do
      wrong = net.merge("vProdLiq" => "17.00")

      expect(issues_of(prod: wrong, ide: {"dhEmi" => "2026-12-13T23:59:00-03:00"})).to eq([])
      expect(issues_of(prod: wrong, ide: {"dhEmi" => "2026-12-14T00:00:00-03:00"})).not_to eq([])
      expect(issues_of(prod: wrong, ide: {"tpAmb" => "2", "dhEmi" => "2026-10-25T23:59:00-03:00"})).to eq([])
      expect(issues_of(prod: wrong, ide: {"tpAmb" => "2", "dhEmi" => "2026-10-26T00:00:00-03:00"})).not_to eq([])
    end
  end

  describe "the ICMS expected at the supply of an advance payment (NB01)" do
    let(:expected) { {"ICMS" => {"ICMSPrevistoPagtoAntecip" => {"vICMSPrevisto" => "0.00"}}} }
    let(:advance) { {"finNFe" => "6", "tpNF" => "1", "tpNFDebito" => "06"} }

    it "is built with forecast_amount and passes the schema" do
      invoice = client.build_invoice do |nfe|
        nfe.number 77
        nfe.issued_at "2026-12-14T10:00:00-03:00"
        nfe.nature_of_operation "Pagamento antecipado"
        nfe.purpose :debit_note
        nfe.debit_note_type "06"
        nfe.issuer tax_id: "11444777000161", name: "EMPRESA LTDA", state_registration: "111111111111", tax_regime: :normal,
          address: {street: "Rua A", number: "100", district: "Centro", city_code: "3550308", city: "Sao Paulo", state: "SP", zip: "01001000"}
        nfe.recipient cnpj: "11222333000181", name: "CLIENTE", state_registration: "123456789",
          address: {street: "Rua B", number: "1", district: "Centro", city_code: "3550308", city: "Sao Paulo", state: "SP", zip: "01001000"}
        nfe.reference "35260111444777000161550010000000011000000015"
        nfe.item do |i|
          i.code "1"
          i.description "Pagamento antecipado"
          i.ncm "84713012"
          i.cfop "5949"
          i.unit "UN"
          i.quantity 1
          i.unit_price "100.00"
          i.icms forecast_amount: "12.00"
          i.ibs_cbs cst: "000", class_code: "000001", base: "100.00", ibs_uf: {rate: "0.10", amount: "0.10"},
            ibs_municipal: {rate: "0", amount: "0"}, cbs: {rate: "0.90", amount: "0.90"}
        end
        nfe.payment :pix
      end

      expect(text(doc(invoice), "//nfe:det/nfe:imposto/nfe:ICMS/nfe:ICMSPrevistoPagtoAntecip/nfe:vICMSPrevisto")).to eq("12.00")
      expect(DfeRb::Nfe::Schemas.nfe_issues(invoice.to_xml)).to eq([])
      expect(invoice.issues.grep(%r{ICMSPrevisto|B25-80|NB01})).to eq([])
    end

    it "is barred from an NFC-e (NB01-10, rej. 1280)" do
      expect(issues_of(imposto: expected, ide: {"mod" => "65"}))
        .to eq(["det[1]/imposto/ICMS/ICMSPrevistoPagtoAntecip: an NFC-e can't carry the ICMS expected at the supply of an advance payment (RV NB01-10, rej. 1280)"])
    end

    it "is barred from a note that isn't an advance payment (NB01-20, rej. 1280)" do
      expect(issues_of(imposto: expected))
        .to eq(["det[1]/imposto/ICMS/ICMSPrevistoPagtoAntecip: only a debit note of type 06 (tpNFDebito) or tpOperGov 4 carries it (RV NB01-20, rej. 1280)"])
      expect(issues_of(imposto: expected, ide: advance)).to eq([])
      expect(issues_of(imposto: expected, ide: {"gCompraGov" => {"tpOperGov" => "4"}})).to eq([])
    end

    it "is required on an advance payment from 01/03/2027 in production and 01/02/2027 in homologação (NB01-30, rej. 1281)" do
      message = a_string_matching(%r{det\[1\]/imposto/ICMS/ICMSPrevistoPagtoAntecip: required on an advance payment .*\(RV NB01-30, rej. 1281\)})

      expect(issues_of(ide: advance.merge("dhEmi" => "2027-02-28T23:59:00-03:00"))).to eq([])
      expect(issues_of(ide: advance.merge("dhEmi" => "2027-03-01T00:00:00-03:00"))).to include(message)
      expect(issues_of(ide: advance.merge("tpAmb" => "2", "dhEmi" => "2027-01-31T23:59:00-03:00"))).to eq([])
      expect(issues_of(ide: advance.merge("tpAmb" => "2", "dhEmi" => "2027-02-01T00:00:00-03:00"))).to include(message)
      expect(issues_of(ide: advance.merge("dhEmi" => "2027-03-01T00:00:00-03:00"), imposto: expected)).to eq([])
      expect(issues_of(ide: {"gCompraGov" => {"tpOperGov" => "4"}, "dhEmi" => "2027-03-01T00:00:00-03:00"})).to include(message)
    end
  end

  describe "RV B25-80, a debit or credit note is for the IBS and the CBS only (rej. 1001)" do
    let(:icms) { {"ICMS" => {"ICMS00" => {"vBC" => "20.00", "pICMS" => "0", "vICMS" => "0"}}} }
    let(:previsto) { {"ICMS" => {"ICMSPrevistoPagtoAntecip" => {"vICMSPrevisto" => "0.00"}}} }
    let(:pis) { {"PIS" => {"PISNT" => {"CST" => "07"}}} }
    let(:ipi) { {"IPI" => {"IPINT" => {"CST" => "53"}}} }

    def barred(group) = "det[1]/imposto/#{group}: a debit or credit note carries IBS and CBS only (RV B25-80, rej. 1001)"

    it "bars the other taxes from a debit or credit note" do
      expect(issues_of(imposto: icms.merge(pis), ide: {"finNFe" => "6", "tpNF" => "1"})).to include(barred("ICMS"), barred("PIS"))
      expect(issues_of(imposto: ipi, ide: {"finNFe" => "5", "tpNF" => "0"})).to include(barred("IPI"))
      expect(issues_of(item: {"impostoDevol" => {"pDevol" => "10.00", "IPI" => {"vIPIDevol" => "0.00"}}}, ide: {"finNFe" => "6", "tpNF" => "1"}))
        .to include("det[1]/impostoDevol: a debit or credit note carries IBS and CBS only (RV B25-80, rej. 1001)")
    end

    it "bars them from the receipt of a payment (tpOperGov 2) too, and leaves a normal note alone" do
      expect(issues_of(imposto: icms, ide: {"gCompraGov" => {"tpOperGov" => "2"}})).to include(barred("ICMS"))
      expect(issues_of(imposto: icms)).to eq([])
    end

    it "spares the credit notes of a refusal or a reduction (03, 04, 06) and the debit note of a loss in stock (07) (exceção 1)" do
      %w[03 04 06].each do |type|
        expect(issues_of(imposto: icms, ide: {"finNFe" => "5", "tpNF" => "0", "tpNFCredito" => type})).not_to include(barred("ICMS"))
      end
      expect(issues_of(imposto: icms, ide: {"finNFe" => "6", "tpNF" => "1", "tpNFDebito" => "07"})).not_to include(barred("ICMS"))
      expect(issues_of(imposto: icms, ide: {"finNFe" => "5", "tpNF" => "0", "tpNFCredito" => "01"})).to include(barred("ICMS"))
    end

    it "lets an advance payment carry the IPI, the ICMS expected at the supply and, in 2026, PIS (exceções 2 to 4)" do
      advance = {"finNFe" => "6", "tpNF" => "1", "tpNFDebito" => "06"}

      expect(issues_of(imposto: ipi.merge(previsto).merge(pis), ide: advance)).to eq([])
      expect(issues_of(imposto: pis, ide: advance.merge("dhEmi" => "2027-01-04T10:00:00-03:00"))).to include(barred("PIS"))
      expect(issues_of(imposto: icms, ide: advance)).to include(barred("ICMS"))
      expect(issues_of(imposto: ipi, ide: advance.merge("tpNFDebito" => "01"))).to include(barred("IPI"))
    end
  end

  describe "vItem and vProd (VB01-10, VB01-20, I11)" do
    let(:item) do
      {"prod" => {"vProd" => "100.00", "vFrete" => "0"},
       "imposto" => {"IBSCBS" => {"gIBSCBS" => {"vIBS" => "0.10", "gCBS" => {"vCBS" => "0.90"}}}, "IS" => {"vIS" => "2.00"}}}
    end

    it "leaves IBS, CBS and IS out of vItem in 2026 and adds them from 2027 (exceção 1)" do
      expect(DfeRb::Nfe::Totals.item_amount(item, 2026)).to eq(100)
      expect(DfeRb::Nfe::Totals.item_amount(item, 2027)).to eq(103)
    end

    it "keeps the reading of NT 2026.008 v1.01's contradiction in one place: the rule's own addends" do
      expect(DfeRb::Nfe::Totals::VITEM_ADDS_IBS_CBS_IS).to be(true)
    end

    it "doesn't hold an import to vItem (exceção 2: CFOP 3xxx)" do
      sold = {"prod" => {"CFOP" => "5102", "qCom" => "1", "vUnCom" => "100.00", "qTrib" => "1", "vUnTrib" => "100.00", "vProd" => "100.00"},
              "imposto" => {}, "vItem" => "90.00"}
      imported = sold.merge("prod" => sold["prod"].merge("CFOP" => "3102"))
      ide = {"finNFe" => "1", "tpAmb" => "1", "dhEmi" => "2027-01-04T10:00:00-03:00"}
      issues = ->(det) { DfeRb::Nfe::Validator.new({"ide" => ide, "det" => [det]}).issues.grep(/vItem/) }

      expect(issues.call(sold)).to eq(["det[1]/vItem: 90.00 differs from the sum of the values that make it up (100.00) (rej. 1105)"])
      expect(issues.call(imported)).to eq([])
    end
  end
end
