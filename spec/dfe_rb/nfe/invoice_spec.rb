RSpec.describe DfeRb::Nfe::Invoice do
  let(:client) { nfe_client(NfeHelpers::FakeTransport.new) }
  let(:ns) { {"nfe" => NfeHelpers::NFE_NS} }

  def doc(invoice) = Nokogiri::XML(invoice.to_xml)

  def text(document, path) = document.at_xpath(path, ns)&.text

  def normal_regime(client, &block)
    client.build_invoice do |nfe|
      nfe.number 77
      nfe.nature_of_operation "Venda"
      nfe.issuer tax_id: "11444777000161", name: "EMPRESA LTDA", state_registration: "111111111111", tax_regime: :normal,
        address: {street: "Rua A", number: "100", district: "Centro", city_code: "3550308", city: "Sao Paulo", state: "SP", zip: "01001000"}
      nfe.recipient cnpj: "11222333000181", name: "CLIENTE", state_registration: "123456789",
        address: {street: "Rua B", number: "1", district: "Centro", city_code: "3550308", city: "Sao Paulo", state: "SP", zip: "01001000"}
      block.call(nfe)
    end
  end

  def taxed_item(nfe, **icms)
    nfe.item do |i|
      i.code "A1"
      i.description "Item"
      i.ncm "84713012"
      i.cfop "5102"
      i.unit "UN"
      i.quantity 3
      i.unit_price "100.00"
      i.icms(cst: "00", origin: 0, base_mode: 3, base: "300.00", rate: "18.00", amount: "54.00", **icms)
      i.pis cst: "01", base: "300.00", rate: "1.65", amount: "4.95"
      i.cofins cst: "01", base: "300.00", rate: "7.60", amount: "22.80"
      i.ibs_cbs cst: "000", class_code: "000001", base: "300.00", ibs_uf: {rate: "0.10", amount: "0.30"},
        ibs_municipal: {rate: "0", amount: "0"}, cbs: {rate: "0.90", amount: "2.70"}
      yield i if block_given?
    end
  end

  describe "a simple invoice (Simples Nacional)" do
    subject(:invoice) { simples_invoice(client) }

    it "produces XML that passes the official schema and the business rules" do
      expect(invoice.issues).to eq([])
      expect(DfeRb::Nfe::Schemas.nfe_issues(invoice.to_xml)).to eq([])
    end

    it "fills defaults and derived fields" do
      document = doc(invoice)

      expect(text(document, "//nfe:ide/nfe:cUF")).to eq("35")
      expect(text(document, "//nfe:ide/nfe:mod")).to eq("55")
      expect(text(document, "//nfe:ide/nfe:tpEmis")).to eq("1")
      expect(text(document, "//nfe:ide/nfe:tpAmb")).to eq("2")
      expect(text(document, "//nfe:ide/nfe:finNFe")).to eq("1")
      expect(text(document, "//nfe:ide/nfe:indPres")).to eq("1")
      expect(text(document, "//nfe:ide/nfe:procEmi")).to eq("0")
      expect(text(document, "//nfe:ide/nfe:verProc")).to eq("dfe_rb #{DfeRb::VERSION}")
      expect(text(document, "//nfe:ide/nfe:idDest")).to eq("2")
      expect(text(document, "//nfe:ide/nfe:indFinal")).to eq("1")
      expect(text(document, "//nfe:ide/nfe:cMunFG")).to eq("3550308")
      expect(text(document, "//nfe:dest/nfe:indIEDest")).to eq("9")
      expect(text(document, "//nfe:transp/nfe:modFrete")).to eq("9")
      expect(text(document, "//nfe:det/nfe:prod/nfe:cEAN")).to eq("SEM GTIN")
      expect(text(document, "//nfe:det/nfe:prod/nfe:uTrib")).to eq("UN")
      expect(text(document, "//nfe:det/nfe:prod/nfe:indTot")).to eq("1")
      expect(text(document, "//nfe:det/nfe:prod/nfe:vProd")).to eq("20.00")
      expect(text(document, "//nfe:total/nfe:ICMSTot/nfe:vNF")).to eq("20.00")
      expect(document.at_xpath("//nfe:det", ns)["nItem"]).to eq("1")
    end

    it "derives the access key, its check digit and the Id" do
      document = doc(invoice)
      id = document.at_xpath("//nfe:infNFe", ns)["Id"]

      expect(id).to eq(invoice.key.id)
      expect(DfeRb::Nfe::AccessKey.valid?(id.delete_prefix("NFe"))).to be(true)
      expect(invoice.key.number).to eq(1)
      expect(invoice.key.tax_id).to eq("11444777000161")
      expect(text(document, "//nfe:ide/nfe:cDV")).to eq(invoice.key.check_digit)
      expect(document.at_xpath("//nfe:infNFe", ns)["versao"]).to eq("4.00")
    end

    it "stays identical between calls, so a retry never changes cNF or the issue time" do
      first = invoice.to_xml
      sleep 1.1
      expect(invoice.to_xml).to eq(first)
      expect(invoice.key.to_s).to eq(invoice.key.to_s)
    end

    it "uses the issuer's UTC offset" do
      clock = Struct.new(:now).new(Time.utc(2026, 9, 29, 15, 0, 0))
      acre = DfeRb::Nfe::Invoice.new(clock: clock) do |nfe|
        nfe.number 1
        nfe.issuer tax_id: "11444777000161", address: {state: "AC"}
      end
      paulista = DfeRb::Nfe::Invoice.new(clock: clock) { |nfe| nfe.issuer(address: {state: "SP"}) }

      expect(acre.resolved["ide"]["dhEmi"].strftime("%:z")).to eq("-05:00")
      expect(acre.resolved["ide"]["dhEmi"].strftime("%H")).to eq("10")
      expect(paulista.resolved["ide"]["dhEmi"].strftime("%:z")).to eq("-03:00")
    end

    it "replaces the recipient name in homologacao and keeps it in production" do
      expect(text(doc(invoice), "//nfe:dest/nfe:xNome")).to eq("NF-E EMITIDA EM AMBIENTE DE HOMOLOGACAO - SEM VALOR FISCAL")

      production = simples_invoice(nfe_client(NfeHelpers::FakeTransport.new, environment: :production))
      document = doc(production)
      expect(text(document, "//nfe:dest/nfe:xNome")).to eq("CLIENTE")
      expect(text(document, "//nfe:ide/nfe:tpAmb")).to eq("1")
    end
  end

  describe "input styles" do
    it "gives the same invoice from a block, a hash, and official names" do
      fixed = Time.new(2026, 9, 29, 10, 0, 0, "-03:00")
      by_block = DfeRb::Nfe::Invoice.new do |nfe|
        nfe.number 5
        nfe.issued_at fixed
        nfe.numeric_code "12345670"
        nfe.issuer name: "ACME", tax_id: "11444777000161", address: {state: "SP"}
      end
      by_hash = DfeRb::Nfe::Invoice.new(number: 5, issued_at: fixed, numeric_code: "12345670",
        issuer: {name: "ACME", tax_id: "11444777000161", address: {state: "SP"}})
      official = DfeRb::Nfe::Invoice.new(nNF: 5, dhEmi: fixed, cNF: "12345670",
        emit: {xNome: "ACME", CNPJ: "11444777000161", enderEmit: {UF: "SP"}})
      snake = DfeRb::Nfe::Invoice.new(n_nf: 5, dh_emi: fixed, c_nf: "12345670",
        emit: {x_nome: "ACME", cnpj: "11444777000161", ender_emit: {uf: "SP"}})

      expect([by_hash, official, snake].map(&:resolved)).to all(eq(by_block.resolved))
    end

    it "supports item hashes and repeated items with their numbers" do
      invoice = simples_invoice(client) do |nfe|
        nfe.items [
          {code: "2", description: "Segundo", ncm: "84713012", cfop: "6102", unit: "UN", quantity: 1, unit_price: "5.00"},
          {code: "3", description: "Terceiro", ncm: "84713012", cfop: "6102", unit: "UN", quantity: 1, unit_price: "5.00"}
        ]
      end

      expect(invoice.resolved["det"].map { |item| item["@nItem"] }).to eq([1, 2, 3])
      expect(invoice.resolved["det"].map { |item| item.dig("prod", "cProd") }).to eq(%w[1 2 3])
    end

    it "accepts official field names inside items" do
      invoice = client.build_invoice { |nfe|
        nfe.item { |i|
          i.c_prod "X"
          i.xProd "Nome"
          i.NCM "84713012"
        }
      }
      expect(invoice.resolved["det"].first["prod"]).to include("cProd" => "X", "xProd" => "Nome", "NCM" => "84713012")
    end

    it "suggests the right name for a typo" do
      expect { client.build_invoice { |nfe| nfe.nature_of_operacion "x" } }
        .to raise_error(NoMethodError, /nature_of_operacion.*did you mean :?"?nature_of_operation/m)
      expect { client.build_invoice { |nfe| nfe.item { |i| i.descripton "x" } } }
        .to raise_error(NoMethodError, /did you mean.*description/)
    end

    it "rejects unknown symbol values with the valid ones" do
      expect { client.build_invoice { |nfe| nfe.issuer tax_regime: :nonsense } }
        .to raise_error(ArgumentError, /unknown value :nonsense for CRT \(use :simples/)
    end

    it "reads a field back when called without arguments" do
      invoice = client.build_invoice { |nfe| nfe.number 9 }
      expect(invoice.scope.number).to eq(9)
    end
  end

  describe "formatted input" do
    it "accepts punctuation in codes wherever removing it gives a valid value" do
      invoice = simples_invoice(client) { |nfe|
        nfe.recipient cnpj: "11.222.333/0001-81", state_registration: "123.456.789.012", address: {zip: "20000-000", phone: "(21) 99999-0000"}
        nfe.item { |i|
          i.code "5"
          i.description "x"
          i.ncm "8471.30.12"
          i.cfop "6.102"
          i.unit "UN"
          i.quantity 1
          i.unit_price "1.00"
          i.icms(csosn: "102", origin: 0)
          i.pis(cst: "07")
          i.cofins(cst: "07")
        }
        nfe.payment :money, "1.00"
      }
      resolved = invoice.resolved

      expect(resolved["dest"]).to include("CNPJ" => "11222333000181", "IE" => "123456789012")
      expect(resolved["dest"]["enderDest"]).to include("CEP" => "20000000", "fone" => "21999990000")
      expect(resolved["det"].last["prod"]).to include("NCM" => "84713012", "CFOP" => "6102")
      expect(invoice.issues).to eq([])
    end

    it "leaves genuinely invalid values alone so the error names them" do
      invoice = simples_invoice(client) { |nfe| nfe.recipient cnpj: "not-a-cnpj" }
      expect(invoice.issues.join).to include("not-a-cnpj")
    end
  end

  describe "recipient inference" do
    def recipient_of(**attributes)
      simples_invoice(client) { |nfe| nfe.recipient(**attributes) }.resolved
    end

    it "marks an internal operation, an interstate one and an export" do
      internal = recipient_of(cnpj: "11222333000181", address: {state: "SP", street: "R", number: "1", district: "C", city_code: "3550308", city: "SP", zip: "01001000"})
      expect(internal["ide"]["idDest"]).to eq(1)

      interstate = recipient_of(cnpj: "11222333000181", address: {state: "RJ", street: "R", number: "1", district: "C", city_code: "3304557", city: "RJ", zip: "20000000"})
      expect(interstate["ide"]["idDest"]).to eq(2)

      foreign = recipient_of(foreign_id: "PASSPORT123", name: "Buyer", address: {state: "EX", street: "R", number: "1", district: "C", city_code: "9999999", city: "EXTERIOR", country_code: "0249"})
      expect(foreign["ide"]["idDest"]).to eq(3)
      expect(foreign["dest"]["indIEDest"]).to eq(9)
    end

    it "sets indIEDest from the state registration, and understands ISENTO" do
      taxpayer = recipient_of(cnpj: "11222333000181", state_registration: "123456789", address: {state: "SP"})
      expect(taxpayer["dest"]["indIEDest"]).to eq(1)
      expect(taxpayer["ide"]["indFinal"]).to eq(0)

      exempt = recipient_of(cnpj: "11222333000181", state_registration: "ISENTO", address: {state: "SP"})
      expect(exempt["dest"]["indIEDest"]).to eq(2)
      expect(exempt["dest"]).not_to have_key("IE")

      explicit = recipient_of(cnpj: "11222333000181", state_registration_indicator: :exempt, address: {state: "SP"})
      expect(explicit["dest"]["indIEDest"]).to eq(2)
    end

    it "keeps the explicit values the developer set" do
      resolved = simples_invoice(client) { |nfe|
        nfe.destination :internal
        nfe.final_consumer false
      }.resolved

      expect(resolved["ide"]["idDest"]).to eq(1)
      expect(resolved["ide"]["indFinal"]).to eq(0)
    end
  end

  describe "regime normal" do
    it "picks the ICMS group from the CST and validates against the schema" do
      invoice = normal_regime(client) { |nfe|
        taxed_item(nfe)
        nfe.payment :credit_card, "300.00"
      }

      expect(invoice.issues).to eq([])
      expect(doc(invoice).at_xpath("//nfe:imposto/nfe:ICMS/nfe:ICMS00", ns)).not_to be_nil
    end

    it "derives every total from the items (IBS/CBS stay out of vNF)" do
      invoice = normal_regime(client) { |nfe|
        taxed_item(nfe) { |i| i.freight "10.00" }
        nfe.item do |i|
          i.code "B2"
          i.description "ST"
          i.ncm "22021000"
          i.cest "0300100"
          i.cfop "5405"
          i.unit "UN"
          i.quantity 1
          i.unit_price "50.00"
          i.icms cst: "10", origin: 0, base_mode: 3, base: "50.00", rate: "18.00", amount: "9.00",
            st_base_mode: 4, st_margin: "40.00", st_base: "70.00", st_rate: "18.00", st_amount: "3.60"
          i.pis cst: "01", base: "50.00", rate: "1.65", amount: "0.83"
          i.cofins cst: "01", base: "50.00", rate: "7.60", amount: "3.80"
          i.ibs_cbs cst: "000", class_code: "000001", base: "50.00", ibs_uf: {rate: "0.10", amount: "0.05"},
            ibs_municipal: {rate: "0", amount: "0"}, cbs: {rate: "0.90", amount: "0.45"}
        end
        nfe.payment :credit_card, "363.60"
      }

      expect(invoice.issues).to eq([])
      document = doc(invoice)
      totals = %w[vBC vICMS vBCST vST vProd vFrete vPIS vCOFINS vNF].to_h { |tag| [tag, text(document, "//nfe:ICMSTot/nfe:#{tag}")] }
      expect(totals).to eq("vBC" => "350.00", "vICMS" => "63.00", "vBCST" => "70.00", "vST" => "3.60", "vProd" => "350.00",
        "vFrete" => "10.00", "vPIS" => "5.78", "vCOFINS" => "26.60", "vNF" => "363.60")
      expect(text(document, "//nfe:IBSCBSTot/nfe:vBCIBSCBS")).to eq("350.00")
      expect(text(document, "//nfe:IBSCBSTot/nfe:gIBS/nfe:vIBS")).to eq("0.35")
      expect(text(document, "//nfe:IBSCBSTot/nfe:gCBS/nfe:vCBS")).to eq("3.15")
      expect(document.at_xpath("//nfe:det[1]//nfe:gIBSCBS/nfe:vIBS", ns).text).to eq("0.30")
    end

    it "computes the change when payments exceed the total" do
      invoice = normal_regime(client) { |nfe|
        taxed_item(nfe)
        nfe.payment :money, "400.00"
      }

      expect(invoice.issues).to eq([])
      expect(text(doc(invoice), "//nfe:pag/nfe:vTroco")).to eq("100.00")
    end

    it "requires IBS/CBS on ordinary notes of regime normal" do
      invoice = normal_regime(client) { |nfe|
        nfe.item do |i|
          i.code "A1"
          i.description "Item"
          i.ncm "84713012"
          i.cfop "5102"
          i.unit "UN"
          i.quantity 1
          i.unit_price "10.00"
          i.icms cst: "00", origin: 0, base_mode: 3, base: "10.00", rate: "18.00", amount: "1.80"
          i.pis cst: "07"
          i.cofins cst: "07"
        end
        nfe.payment :money, "10.00"
      }

      expect(invoice.issues).to contain_exactly(a_string_matching(%r{det\[1\]/imposto/IBSCBS: mandatory for regime normal}))
    end
  end

  describe "tax groups" do
    def item_xml(**kwargs)
      invoice = simples_invoice(client) { |nfe|
        nfe.item do |i|
          i.code "9"
          i.description "Variante"
          i.ncm "84713012"
          i.cfop "6102"
          i.unit "UN"
          i.quantity 1
          i.unit_price "10.00"
          kwargs[:tax].call(i)
        end
      }
      Nokogiri::XML(invoice.to_xml(strict: false)).xpath("//nfe:det[last()]/nfe:imposto", ns).first
    end

    {
      "00" => ["ICMS00", {origin: 0, base_mode: 3, base: "10.00", rate: "18.00", amount: "1.80"}],
      "02" => ["ICMS02", {origin: 0, mono_base: "1.0000", mono_ad_rem: "1.0000", mono_amount: "1.00"}],
      "10" => ["ICMS10", {origin: 0, base_mode: 3, base: "10.00", rate: "18.00", amount: "1.80", st_base_mode: 4, st_base: "10.00", st_rate: "18.00", st_amount: "1.80"}],
      "20" => ["ICMS20", {origin: 0, base_mode: 3, base_reduction: "10.00", base: "9.00", rate: "18.00", amount: "1.62"}],
      "30" => ["ICMS30", {origin: 0, st_base_mode: 4, st_base: "10.00", st_rate: "18.00", st_amount: "1.80"}],
      "40" => ["ICMS40", {origin: 0}],
      "41" => ["ICMS40", {origin: 0}],
      "50" => ["ICMS40", {origin: 0}],
      "51" => ["ICMS51", {origin: 0}],
      "60" => ["ICMS60", {origin: 0, retained_st_base: "10.00", retained_st_rate: "18.00", retained_st_amount: "1.80"}],
      "70" => ["ICMS70", {origin: 0, base_mode: 3, base_reduction: "10.00", base: "9.00", rate: "18.00", amount: "1.62", st_base_mode: 4, st_base: "9.00", st_rate: "18.00", st_amount: "1.62"}],
      "90" => ["ICMS90", {origin: 0, base_mode: 3, base: "10.00", rate: "18.00", amount: "1.80"}]
    }.each do |cst, (tag, fields)|
      it "maps ICMS CST #{cst} to <#{tag}>" do
        imposto = item_xml(tax: ->(i) {
          i.icms(cst: cst, **fields)
          i.pis cst: "07"
          i.cofins cst: "07"
        })

        expect(imposto.at_xpath("nfe:ICMS/nfe:#{tag}/nfe:CST", ns).text).to eq(cst)
      end
    end

    {
      "101" => ["ICMSSN101", {origin: 0, credit_rate: "1.25", credit_amount: "0.13"}],
      "102" => ["ICMSSN102", {origin: 0}],
      "103" => ["ICMSSN102", {origin: 0}],
      "201" => ["ICMSSN201", {origin: 0, st_base_mode: 4, st_base: "10.00", st_rate: "18.00", st_amount: "1.80", credit_rate: "1.25", credit_amount: "0.13"}],
      "202" => ["ICMSSN202", {origin: 0, st_base_mode: 4, st_base: "10.00", st_rate: "18.00", st_amount: "1.80"}],
      "300" => ["ICMSSN102", {origin: 0}],
      "400" => ["ICMSSN102", {origin: 0}],
      "500" => ["ICMSSN500", {origin: 0}],
      "900" => ["ICMSSN900", {origin: 0}]
    }.each do |csosn, (tag, fields)|
      it "maps CSOSN #{csosn} to <#{tag}>" do
        imposto = item_xml(tax: ->(i) {
          i.icms(csosn: csosn, **fields)
          i.pis cst: "07"
          i.cofins cst: "07"
        })

        expect(imposto.at_xpath("nfe:ICMS/nfe:#{tag}/nfe:CSOSN", ns).text).to eq(csosn)
      end
    end

    it "detects the partition (ICMSPart) and repass (ICMSST) variants" do
      part = item_xml(tax: ->(i) {
        i.icms cst: "10", origin: 0, base_mode: 3, base: "10.00", rate: "18.00", amount: "1.80", st_base_mode: 4, st_base: "10.00",
          st_rate: "18.00", st_amount: "1.80", operation_base_rate: "100.00", st_state: "RJ"
        i.pis cst: "07"
        i.cofins cst: "07"
      })
      expect(part.at_xpath("nfe:ICMS/nfe:ICMSPart/nfe:UFST", ns).text).to eq("RJ")

      repass = item_xml(tax: ->(i) {
        i.icms cst: "60", origin: 0, retained_st_base: "10.00", retained_st_amount: "1.80", destination_st_base: "10.00", destination_st_amount: "1.80"
        i.pis cst: "07"
        i.cofins cst: "07"
      })
      expect(repass.at_xpath("nfe:ICMS/nfe:ICMSST/nfe:CST", ns).text).to eq("60")
    end

    it "rejects a CST it doesn't know" do
      expect { simples_invoice(client) { |nfe| nfe.item { |i| i.icms cst: "77" } } }.to raise_error(ArgumentError, /unknown ICMS CST/)
      expect { simples_invoice(client) { |nfe| nfe.item { |i| i.icms origin: 0 } } }.to raise_error(ArgumentError, /needs cst/)
    end

    it "maps PIS and COFINS CSTs to Aliq, Qtde, NT and Outr" do
      imposto = item_xml(tax: ->(i) {
        i.icms csosn: "102", origin: 0
        i.pis cst: "03", quantity_base: "1.0000", unit_rate: "2.0000", amount: "2.00"
        i.cofins cst: "99", base: "10.00", rate: "7.60", amount: "0.76"
      })
      expect(imposto.at_xpath("nfe:PIS/nfe:PISQtde/nfe:qBCProd", ns).text).to eq("1")
      expect(imposto.at_xpath("nfe:COFINS/nfe:COFINSOutr/nfe:pCOFINS", ns).text).to eq("7.60")

      taxed = item_xml(tax: ->(i) {
        i.icms csosn: "102", origin: 0
        i.pis cst: "01", base: "10.00", rate: "1.65", amount: "0.17"
        i.cofins cst: "04"
      })
      expect(taxed.at_xpath("nfe:PIS/nfe:PISAliq/nfe:pPIS", ns).text).to eq("1.65")
      expect(taxed.at_xpath("nfe:COFINS/nfe:COFINSNT/nfe:CST", ns).text).to eq("04")
    end

    it "builds IPI with taxed or non-taxed groups and a default framework code" do
      taxed = item_xml(tax: ->(i) {
        i.icms csosn: "102", origin: 0
        i.ipi cst: "50", base: "10.00", rate: "5.00", amount: "0.50"
        i.pis cst: "07"
        i.cofins cst: "07"
      })
      expect(taxed.at_xpath("nfe:IPI/nfe:cEnq", ns).text).to eq("999")
      expect(taxed.at_xpath("nfe:IPI/nfe:IPITrib/nfe:vIPI", ns).text).to eq("0.50")

      exempt = item_xml(tax: ->(i) {
        i.icms csosn: "102", origin: 0
        i.ipi cst: "53", framework_code: "301"
        i.pis cst: "07"
        i.cofins cst: "07"
      })
      expect(exempt.at_xpath("nfe:IPI/nfe:cEnq", ns).text).to eq("301")
      expect(exempt.at_xpath("nfe:IPI/nfe:IPINT/nfe:CST", ns).text).to eq("53")
    end
  end

  describe "business rules" do
    def issues_of(&block) = simples_invoice(client, &block).issues

    it "flags a CFOP that doesn't fit the operation" do
      expect(issues_of { |nfe|
        nfe.item { |i|
          i.code "2"
          i.description "x"
          i.ncm "84713012"
          i.cfop "5102"
          i.unit "UN"
          i.quantity 1
          i.unit_price "1.00"
          i.icms(csosn: "102", origin: 0)
          i.pis(cst: "07")
          i.cofins(cst: "07")
        }
        nfe.payment :money, "21.00"
      })
        .to include(a_string_matching(/det\[2\]\/prod\/CFOP: 5102 does not fit the operation.*must start with 6/))
    end

    it "flags invalid CNPJs" do
      expect(issues_of { |nfe| nfe.recipient cnpj: "11222333000182" }).to include(a_string_matching(%r{dest/CNPJ: 11222333000182 is not a valid CNPJ}))
    end

    it "flags reserved series and a payment below the total" do
      expect(issues_of { |nfe| nfe.series 920 }).to include(a_string_matching(/serie: 920 is reserved/))
      low = simples_invoice(client) { |nfe|
        nfe.item { |i|
          i.code "5"
          i.description "x"
          i.ncm "84713012"
          i.cfop "6102"
          i.unit "UN"
          i.quantity 1
          i.unit_price "30.00"
          i.icms(csosn: "102", origin: 0)
          i.pis(cst: "07")
          i.cofins(cst: "07")
        }
      }
      expect(low.issues).to include(a_string_matching(/pag: the payments \(20.00\) are less than the invoice total \(50.00\)/))
    end

    it "flags totals that disagree with the items" do
      invoice = simples_invoice(client) { |nfe| nfe.totals icms_tot: {v_nf: "99.00"} }
      expect(invoice.issues).to include(a_string_matching(%r{total/ICMSTot/vNF: 99.00 differs from the sum of the items \(20.00\)}))
    end

    it "flags an item whose value isn't quantity x price" do
      invoice = simples_invoice(client) { |nfe|
        nfe.item { |i|
          i.code "5"
          i.description "x"
          i.ncm "84713012"
          i.cfop "6102"
          i.unit "UN"
          i.quantity 2
          i.unit_price "10.00"
          i.total "25.00"
          i.icms(csosn: "102", origin: 0)
          i.pis(cst: "07")
          i.cofins(cst: "07")
        }
      }
      expect(invoice.issues).to include(a_string_matching(%r{det\[2\]/prod/vProd: 25.00 differs from quantity x unit price \(20.00\) \(rej. 629\)}))
    end

    it "flags a wrong GTIN check digit and accepts a right one" do
      bad = simples_invoice(client) { |nfe|
        nfe.item { |i|
          i.code "6"
          i.gtin "7891000100104"
          i.description "x"
          i.ncm "84713012"
          i.cfop "6102"
          i.unit "UN"
          i.quantity 1
          i.unit_price "1.00"
          i.icms(csosn: "102", origin: 0)
          i.pis(cst: "07")
          i.cofins(cst: "07")
        }
      }
      expect(bad.issues.join).to include("wrong GTIN check digit")

      good = simples_invoice(client) { |nfe|
        nfe.item { |i|
          i.code "6"
          i.gtin "7891000100103"
          i.taxable_gtin "7891000100103"
          i.description "x"
          i.ncm "84713012"
          i.cfop "6102"
          i.unit "UN"
          i.quantity 1
          i.unit_price "1.00"
          i.icms(csosn: "102", origin: 0)
          i.pis(cst: "07")
          i.cofins(cst: "07")
        }
        nfe.payment :money, "1.00"
      }
      expect(good.issues.join).not_to include("GTIN")
    end

    it "requires a payment" do
      invoice = client.build_invoice do |nfe|
        nfe.number 1
        nfe.issuer tax_id: "11444777000161", name: "X", tax_regime: :simples, state_registration: "1", address: {state: "SP", city_code: "3550308"}
      end
      expect(invoice.issues.join).to include("dest: the recipient is mandatory")
    end

    it "lets advanced users skip the business rules but never the schema" do
      invoice = simples_invoice(client) { |nfe| nfe.series 920 }

      expect(invoice.issues).not_to be_empty
      expect { invoice.to_xml }.to raise_error(DfeRb::ValidationError, /reserved/)
      expect(invoice.to_xml(strict: false)).to start_with("<NFe")
      expect { client.sign(invoice) }.to raise_error(DfeRb::ValidationError)
      expect(client.sign(invoice, strict: false).key).to be_a(String)
    end
  end

  describe "value formats" do
    it "reports every bad value at once" do
      invoice = simples_invoice(client) { |nfe|
        nfe.nature_of_operation "x" * 61
        nfe.item { |i|
          i.code "5"
          i.description "preco €"
          i.ncm "84713012"
          i.cfop "6102"
          i.unit "UN"
          i.quantity "abc"
          i.unit_price "1.00"
        }
      }

      found = invoice.issues
      expect(found).to include(a_string_matching(/ide\/natOp: is too long \(61 characters, maximum 60\)/))
      expect(found).to include(a_string_matching(/xProd: contains characters outside ISO-8859-1/))
      expect(found).to include(a_string_matching(/qCom: expected a number/))
    end

    it "cleans control characters and surrounding spaces from text" do
      invoice = simples_invoice(client) { |nfe| nfe.additional_info additional_info: "  linha 1\nlinha 2\t " }
      expect(text(doc(invoice), "//nfe:infAdic/nfe:infCpl")).to eq("linha 1 linha 2")
    end

    it "escapes markup in text" do
      invoice = simples_invoice(client) { |nfe| nfe.additional_info additional_info: "A & B <C>" }
      expect(invoice.to_xml).to include("A &amp; B &lt;C&gt;")
      expect(text(doc(invoice), "//nfe:infAdic/nfe:infCpl")).to eq("A & B <C>")
    end
  end
end
