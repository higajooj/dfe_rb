RSpec.describe DfeRb::Nfe::NoIeRules do
  # The issues about an issuer without IE, of a note whose first item carries `imposto`.
  def issues_of(emit: {}, ide: {}, imposto: {"IBSCBS" => {"cClassTrib" => "000001"}}, items: nil)
    tree = {"ide" => {"mod" => "55", "tpNF" => "1", "finNFe" => "1", "tpAmb" => "1", "dhEmi" => "2026-11-16T09:00:00-03:00"}.merge(ide),
            "emit" => {"CNPJ" => "11444777000161", "CRT" => "3", "enderEmit" => {"UF" => "SP"}}.merge(emit),
            "det" => items || [{"prod" => {"CFOP" => "5551"}, "imposto" => imposto}]}
    DfeRb::Nfe::Validator.new(tree).issues.grep(/rej\. (156|157|158|161|162)\)/)
  end

  it "asks nothing of an issuer with an IE, or with ISENTO, which is the CCC's to judge" do
    with_icms = {"ICMS" => {"ICMS00" => {}}}

    expect(issues_of(emit: {"IE" => "111111111111"}, imposto: with_icms)).to eq([])
    expect(issues_of(emit: {"IE" => "ISENTO"}, imposto: with_icms)).to eq([])
  end

  it "takes a note with only IBS/CBS from an issuer without IE" do
    expect(issues_of).to eq([])
    expect(issues_of(emit: {"IE" => ""})).to eq([])
  end

  describe "ICMS (N01-10, rej. 161)" do
    it "refuses the ICMS group and the interstate ICMS on an issuer without IE" do
      imposto = {"ICMS" => {"ICMS00" => {"CST" => "00"}}, "ICMSUFDest" => {}, "IBSCBS" => {"cClassTrib" => "000001"}}

      expect(issues_of(imposto: imposto)).to eq([
        "det[1]/imposto/ICMS: an issuer without state registration can't carry ICMS, only IBS/CBS (RV N01-10, NT 2026.007, rej. 161)",
        "det[1]/imposto/ICMSUFDest: an issuer without state registration can't carry ICMS, only IBS/CBS (RV N01-10, NT 2026.007, rej. 161)"
      ])
    end

    it "lets a return and the credit note of type 03 carry it" do
      imposto = {"ICMS" => {"ICMS00" => {"CST" => "00"}}, "IBSCBS" => {"cClassTrib" => "000001"}}

      expect(issues_of(imposto: imposto, ide: {"finNFe" => "4"})).to eq([])
      expect(issues_of(imposto: imposto, ide: {"finNFe" => "5", "tpNFCredito" => "03"})).to eq([])
      expect(issues_of(imposto: imposto, ide: {"finNFe" => "5", "tpNFCredito" => "06"}).size).to eq(1)
    end
  end

  describe "IBS/CBS (UB12-11, rej. 162)" do
    it "requires the group on every item, with no exception, a return included" do
      items = [{"prod" => {"CFOP" => "5551"}, "imposto" => {"IBSCBS" => {}}}, {"prod" => {"CFOP" => "5551"}, "imposto" => {}}]

      expect(issues_of(items: items)).to eq([
        "det[2]/imposto/IBSCBS: an issuer without state registration carries IBS/CBS on every item (RV UB12-11, NT 2026.007, rej. 162)"
      ])
      expect(issues_of(imposto: {}, ide: {"finNFe" => "4"}).size).to eq(1)
    end

    it "asks it of a CRT 1 issuer as well, since the rule is on the missing IE alone" do
      expect(issues_of(emit: {"CRT" => "1"}, imposto: {}).size).to eq(1)
    end
  end

  describe "the issuer's identity (C17-43, C18-50)" do
    it "refuses a CPF issuer (rej. 157)" do
      expect(issues_of(emit: {"CNPJ" => nil, "CPF" => "52998224725"})).to eq([
        "emit/CNPJ: an issuer without state registration is identified by CNPJ, not CPF (RV C17-43, NT 2026.007, rej. 157)"
      ])
      expect(issues_of(emit: {"CNPJ" => nil, "CPF" => "52998224725", "IE" => "111111111111"})).to eq([])
    end

    it "refuses the tax substitute's IE (rej. 158)" do
      expect(issues_of(emit: {"IEST" => "123456789"})).to eq([
        "emit/IEST: an issuer without state registration can't give the tax substitute's IE (RV C18-50, NT 2026.007, rej. 158)"
      ])
    end
  end

  describe "an NFC-e (C17-42, rej. 156)" do
    it "is refused until 2033" do
      expect(issues_of(ide: {"mod" => "65"})).to eq([
        "emit/IE: an NFC-e (modelo 65) can't be issued without the issuer's state registration until 2033 (RV C17-42, NT 2026.007, rej. 156)"
      ])
      expect(issues_of(ide: {"mod" => "65", "dhEmi" => "2032-12-31T23:59:00-03:00"}).size).to eq(1)
      expect(issues_of(ide: {"mod" => "65", "dhEmi" => "2033-01-01T00:00:00-03:00"})).to eq([])
    end

    it "is left to the NFC-e's own rules otherwise: no CNPJ or IEST rule of the NF-e's" do
      expect(issues_of(ide: {"mod" => "65"}, emit: {"CNPJ" => nil, "CPF" => "52998224725", "IEST" => "1"}).size).to eq(1)
    end

    it "takes an NFC-e with IE" do
      expect(issues_of(ide: {"mod" => "65"}, emit: {"IE" => "111111111111"})).to eq([])
    end
  end

  describe "from the days v1.11 gives" do
    let(:imposto) { {"ICMS" => {"ICMS00" => {}}, "IBSCBS" => {}} }

    it "waits for 26/10/2026 in homologação and 16/11/2026 in production" do
      expect(issues_of(imposto: imposto, ide: {"dhEmi" => "2026-11-15T23:59:00-03:00"})).to eq([])
      expect(issues_of(imposto: imposto, ide: {"dhEmi" => "2026-11-16T00:00:00-03:00"}).size).to eq(1)
      expect(issues_of(imposto: imposto, ide: {"tpAmb" => "2", "dhEmi" => "2026-10-25T23:59:00-03:00"})).to eq([])
      expect(issues_of(imposto: imposto, ide: {"tpAmb" => "2", "dhEmi" => "2026-10-26T00:00:00-03:00"}).size).to eq(1)
    end
  end

  describe "through the builder" do
    let(:client) { nfe_client(NfeHelpers::FakeTransport.new) }

    def no_ie_note(tax_regime: :normal)
      client.build_invoice do |nfe|
        nfe.series 1
        nfe.number 5
        nfe.nature_of_operation "Alienacao de ativo imobilizado"
        nfe.issued_at "2026-11-16T09:00:00-03:00"
        nfe.issuer tax_id: "11.444.777/0001-61", name: "EMPRESA TESTE LTDA", tax_regime: tax_regime,
          address: {street: "Rua A", number: "100", district: "Centro", city_code: "3550308", city: "Sao Paulo", state: "SP", zip: "01001000"}
        nfe.recipient cnpj: "11222333000181", name: "CLIENTE",
          address: {street: "Rua B", number: "1", district: "Centro", city_code: "3550308", city: "Sao Paulo", state: "SP", zip: "01001000"}
        nfe.item do |i|
          i.code "1"
          i.description "Maquina"
          i.ncm "84713012"
          i.cfop "5551"
          i.unit "UN"
          i.quantity 1
          i.unit_price "100.00"
          yield i if block_given?
        end
        nfe.payment :no_payment
      end
    end

    it "refuses an ICMS group and asks for the IBS/CBS one, before SEFAZ does" do
      note = no_ie_note { |i| i.icms cst: "00", origin: 0, base_mode: 3, base: "100.00", rate: "18.00", amount: "18.00" }

      expect(note.issues).to include(a_string_matching(/imposto\/ICMS: an issuer without state registration can't carry ICMS.*rej\. 161/),
        a_string_matching(/imposto\/IBSCBS: an issuer without state registration carries IBS\/CBS.*rej\. 162/))
    end

    it "takes a note with the IBS/CBS group alone, which the schema accepts without ICMS or IE" do
      note = no_ie_note { |i| i.ibs_cbs cst: "000", class_code: "000001", base: "100.00", ibs_uf: {rate: "0.10", amount: "0.10"}, ibs_municipal: {rate: "0", amount: "0"}, cbs: {rate: "0.90", amount: "0.90"} }

      expect(note.issues).to eq([])
      expect(note.to_xml).not_to include("<IE>")
    end
  end
end
