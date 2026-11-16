RSpec.describe DfeRb::Nfe::ReferenceRules do
  # Keys of notes of the same issuer (2026-09, 2027-01) and of another one.
  let(:key_2026) { "35260911444777000161550010000000011000000015" }
  let(:key_2026_b) { "35260911444777000161550010000000021000000016" }
  let(:key_2027) { "35270111444777000161550010000000011000000015" }
  let(:other_issuer) { "35260922333444000181550010000000021000000016" }

  def reference(key) = {"DFeReferenciado" => {"chaveAcesso" => key}}

  # The rules' issues on a note of one item per element of `items` (a return unless told).
  def issues_of(references: [], items: [{}], ide: {}, emit: nil, cfop: "5202")
    tree = {"ide" => {"mod" => "55", "tpNF" => "1", "finNFe" => "4", "tpAmb" => "1", "dhEmi" => "2026-11-16T09:00:00-03:00",
                      "NFref" => references}.merge(ide),
            "det" => items.map { |item| {"prod" => {"CFOP" => cfop}}.merge(item) }}
    tree["emit"] = emit if emit
    DfeRb::Nfe::Validator.new(tree).issues.grep(/rej\. (255|321|1010|1072|1130|1193)\)|IBSCBS: mandatory/)
  end

  describe "one note in the header of a return (B25-40, rej. 255)" do
    it "refuses a return with two header keys, and tells where several go" do
      expect(issues_of(references: [{"refNFe" => key_2026}, {"refNFe" => key_2026_b}])).to eq([
        "ide/NFref: a return references one note only in the header, 2 given (RV B25-40, rej. 255); " \
        "a return of several notes names each on its items (det/DFeReferenciado)"
      ])
      expect(issues_of(references: [{"refNFe" => key_2026}])).to eq([])
    end

    it "holds a complement and the credit notes of types 1, 3 and 4 to it as well, and no other note" do
      references = [{"refNFe" => key_2026}, {"refNFe" => key_2026_b}]

      expect(issues_of(references: references, ide: {"finNFe" => "2"}).size).to eq(1)
      %w[01 03 04].each do |type|
        expect(issues_of(references: references, ide: {"finNFe" => "5", "tpNFCredito" => type}))
          .to contain_exactly(a_string_matching(/credit note of type #{type} references one note only/))
      end
      expect(issues_of(references: references, ide: {"finNFe" => "5", "tpNFCredito" => "06"})).to eq([])
      expect(issues_of(references: references, ide: {"finNFe" => "1"})).to eq([])
    end

    it "asks it of a return from 09/11/2026 in homologação and 16/11/2026 in production, as v1.53 dates it" do
      references = [{"refNFe" => key_2026}, {"refNFe" => key_2026_b}]

      expect(issues_of(references: references, ide: {"dhEmi" => "2026-11-15T23:59:00-03:00"})).to eq([])
      expect(issues_of(references: references, ide: {"tpAmb" => "2", "dhEmi" => "2026-11-08T23:59:00-03:00"})).to eq([])
      expect(issues_of(references: references, ide: {"tpAmb" => "2", "dhEmi" => "2026-11-09T00:00:00-03:00"}).size).to eq(1)
    end
  end

  describe "where a return references its note (VC02-14, VC02-05)" do
    it "takes the key in the header, or on every item" do
      expect(issues_of(references: [{"refNFe" => key_2026}], items: [{}, {}])).to eq([])
      expect(issues_of(items: [reference(key_2026), reference(key_2026)])).to eq([])
    end

    it "refuses a return that references nothing, item by item (rej. 321)" do
      expect(issues_of(items: [reference(key_2026), {}, {}])).to eq([
        "det[2]/DFeReferenciado: a return references the note it returns, in the header (ide/NFref, one key) or on every item (RV VC02-14, rej. 321)",
        "det[3]/DFeReferenciado: a return references the note it returns, in the header (ide/NFref, one key) or on every item (RV VC02-14, rej. 321)"
      ])
    end

    it "leaves the items of CFOP 5921 and 6921 out of it (NT 2013/005)" do
      expect(issues_of(cfop: "5921")).to eq([])
      expect(issues_of(cfop: "6921")).to eq([])
    end

    it "refuses a return that references in the header and on an item at once (rej. 1010)" do
      expect(issues_of(references: [{"refNFe" => key_2026}], items: [reference(key_2026), {}])).to eq([
        "det[1]/DFeReferenciado: the note references documents in the header (ide/NFref) and on its items; " \
        "give one or the other (RV VC02-05, VC02-14, rej. 1010)"
      ])
    end

    it "asks it of a note from 01/09/2026 in homologação and 03/11/2026 in production" do
      expect(issues_of(ide: {"dhEmi" => "2026-11-02T23:59:00-03:00"})).to eq([])
      expect(issues_of(ide: {"dhEmi" => "2026-11-03T00:00:00-03:00"}).size).to eq(1)
      expect(issues_of(ide: {"tpAmb" => "2", "dhEmi" => "2026-08-31T23:59:00-03:00"})).to eq([])
      expect(issues_of(ide: {"tpAmb" => "2", "dhEmi" => "2026-09-01T00:00:00-03:00"}).size).to eq(1)
    end

    it "asks only a return to reference its note" do
      expect(issues_of(ide: {"finNFe" => "1"})).to eq([])
      expect(issues_of(ide: {"finNFe" => "2"})).to eq([])
    end
  end

  describe "a duplicate item reference (VC02-20, rej. 1072)" do
    let(:items) { [{"DFeReferenciado" => {"chaveAcesso" => key_2026, "nItem" => "1"}}, {"DFeReferenciado" => {"chaveAcesso" => key_2026, "nItem" => "1"}}] }

    it "waits for a date: the NT says \"implementação futura\" for both environments" do
      expect(described_class::DUPLICATE_ITEM_REFERENCE_SINCE).to eq("1" => nil, "2" => nil)
      expect(issues_of(items: items, ide: {"dhEmi" => "2030-01-02T09:00:00-03:00"})).to eq([])
    end

    it "refuses the same key and item twice once a date is published, in production only after it" do
      stub_const("DfeRb::Nfe::ReferenceRules::DUPLICATE_ITEM_REFERENCE_SINCE",
        {"2" => nil, "1" => Time.new(2027, 3, 1, 0, 0, 0, "-03:00")})

      expect(issues_of(items: items, ide: {"dhEmi" => "2027-02-28T23:59:00-03:00"})).to eq([])
      expect(issues_of(items: items, ide: {"dhEmi" => "2027-03-01T00:00:00-03:00"})).to eq([
        "det[2]/DFeReferenciado: item 1 of #{key_2026} is already referenced by det[1] (RV VC02-20, rej. 1072)"
      ])
      expect(issues_of(items: items, ide: {"tpAmb" => "2", "dhEmi" => "2027-03-01T00:00:00-03:00"})).to eq([])
    end

    it "takes the same key on other items, or without nItem, as a return of several items of one note" do
      stub_const("DfeRb::Nfe::ReferenceRules::DUPLICATE_ITEM_REFERENCE_SINCE", {"2" => nil, "1" => Time.new(2026, 1, 1, 0, 0, 0, "-03:00")})
      other_item = [items.first, {"DFeReferenciado" => {"chaveAcesso" => key_2026, "nItem" => "2"}}]

      expect(issues_of(items: other_item)).to eq([])
      expect(issues_of(items: [reference(key_2026), reference(key_2026)])).to eq([])
    end
  end

  describe "the documents the items reference" do
    it "makes the items of a note other than a return reference one document (VC02-30, rej. 1130)" do
      items = [reference(key_2026), reference(key_2026), reference(key_2026_b)]

      expect(issues_of(items: items, ide: {"finNFe" => "6", "tpNFDebito" => "04"})).to eq([
        "det[3]/DFeReferenciado/chaveAcesso: the items of this note reference more than one document, " \
        "#{key_2026} and #{key_2026_b} (RV VC02-30, rej. 1130)"
      ])
      expect(issues_of(items: items)).to eq([])
      expect(issues_of(items: items, ide: {"finNFe" => "6", "tpNFDebito" => "03"})).to eq([])
      expect(issues_of(items: items, ide: {"finNFe" => "6", "tpNFDebito" => "07"})).to eq([])
    end

    it "makes the items of a return reference one issuer (VC02-40, rej. 1193), by CNPJ base" do
      expect(issues_of(items: [reference(key_2026), reference(key_2026_b)])).to eq([])
      expect(issues_of(items: [reference(key_2026), reference(other_issuer)])).to eq([
        "det[2]/DFeReferenciado/chaveAcesso: a return references the same issuer on every item; this key's " \
        "(22333444) isn't the first item's (11444777) (RV VC02-40, rej. 1193)"
      ])
    end

    it "leaves the issuer of a Nota Fiscal Avulsa, whose key carries SEFAZ's CNPJ, to SEFAZ" do
      nfa = "35260999999999000199558900000000011000000013"

      expect(issues_of(items: [reference(key_2026), reference(nfa)])).to eq([])
    end

    it "asks them from 09/11/2026 in homologação and 16/11/2026 in production" do
      items = [reference(key_2026), reference(other_issuer)]

      expect(issues_of(items: items, ide: {"dhEmi" => "2026-11-15T23:59:00-03:00"})).to eq([])
      expect(issues_of(items: items, ide: {"tpAmb" => "2", "dhEmi" => "2026-11-09T00:00:00-03:00"}).size).to eq(1)
    end
  end

  describe "IBS/CBS on a return or a complement (UB12-10, exception 1)" do
    let(:normal) { {"CRT" => "3"} }

    def ibs_cbs_issues(references: [], items: [{}], ide: {})
      issues_of(references: references, items: items, ide: {"tpAmb" => "2", "dhEmi" => "2027-01-05T09:00:00-03:00"}.merge(ide), emit: normal)
        .grep(/IBSCBS: mandatory/)
    end

    it "requires it in 2027 of a return that references a note of 2027" do
      expect(ibs_cbs_issues(references: [{"refNFe" => key_2027}])).to eq(
        ["det[1]/imposto/IBSCBS: mandatory for regime normal since 01/07/2026 (rej. 1115)"]
      )
      expect(ibs_cbs_issues(items: [reference(key_2027)]).size).to eq(1)
      expect(ibs_cbs_issues(references: [{"refNFe" => key_2027}], ide: {"finNFe" => "2"}).size).to eq(1)
    end

    it "keeps the exception for a note of 2026, whichever way it is referenced" do
      expect(ibs_cbs_issues(references: [{"refNFe" => key_2026}])).to eq([])
      expect(ibs_cbs_issues(items: [reference(key_2026)])).to eq([])
      expect(ibs_cbs_issues(references: [{"refNFe" => key_2026}], ide: {"finNFe" => "2"})).to eq([])
    end

    it "keeps it when the notes referenced are of both years, or when none can be read, and leaves that to SEFAZ" do
      expect(ibs_cbs_issues(items: [reference(key_2026), reference(key_2027)])).to eq([])
      expect(ibs_cbs_issues).to eq([])
      expect(ibs_cbs_issues(references: [{"refNF" => {"AAMM" => "2701"}}])).to eq([])
    end

    it "reads the year of the key's AAMM, where the note is issued in 2026 and the key's month is the last of it" do
      december = "35261211444777000161550010000000011000000015"
      january = "35270111444777000161550010000000011000000015"

      expect(ibs_cbs_issues(references: [{"refNFe" => december}])).to eq([])
      expect(ibs_cbs_issues(references: [{"refNFe" => january}]).size).to eq(1)
    end

    it "asks it of no other note than a return or a complement" do
      expect(ibs_cbs_issues(ide: {"finNFe" => "1"}).size).to eq(1)
    end
  end

  describe "through the builder" do
    let(:client) { nfe_client(NfeHelpers::FakeTransport.new) }

    def return_note(references: [])
      client.build_invoice do |nfe|
        nfe.series 1
        nfe.number 7
        nfe.nature_of_operation "Devolucao de venda"
        nfe.issued_at "2026-11-16T09:00:00-03:00"
        nfe.purpose :return
        nfe.issuer tax_id: "11.444.777/0001-61", name: "EMPRESA TESTE LTDA", state_registration: "111111111111", tax_regime: :simples,
          address: {street: "Rua A", number: "100", district: "Centro", city_code: "3550308", city: "Sao Paulo", state: "SP", zip: "01001000"}
        nfe.recipient cnpj: "11222333000181", name: "CLIENTE",
          address: {street: "Rua B", number: "1", district: "Centro", city_code: "3304557", city: "Rio de Janeiro", state: "RJ", zip: "20000000"}
        references.each { |key| nfe.reference key: key }
        yield nfe
        nfe.payment :no_payment
      end
    end

    def return_item(nfe, code)
      nfe.item do |i|
        i.code code
        i.description "Produto #{code}"
        i.ncm "84713012"
        i.cfop "6202"
        i.unit "UN"
        i.quantity 1
        i.unit_price "10.00"
        i.icms csosn: "102", origin: :domestic
        i.pis cst: "07"
        i.cofins cst: "07"
        yield i if block_given?
      end
    end

    it "puts a return's key on the item, by name or by position, with the item of the note it returns" do
      note = return_note do |nfe|
        return_item(nfe, "1") { |i| i.referenced_dfe key: key_2026, item_number: 3 }
        return_item(nfe, "2") { |i| i.referenced_dfe key_2026 }
      end

      expect(note.resolved["det"].map { |item| item["DFeReferenciado"] }).to eq([
        {"chaveAcesso" => key_2026, "nItem" => 3}, {"chaveAcesso" => key_2026}
      ])
      expect(note.issues).to eq([])
      expect(note.to_xml).to include("<DFeReferenciado><chaveAcesso>#{key_2026}</chaveAcesso><nItem>3</nItem></DFeReferenciado>")
    end

    it "refuses a return with two header keys before SEFAZ does" do
      note = return_note(references: [key_2026, key_2026_b]) { |nfe| return_item(nfe, "1") }

      expect(note.issues).to contain_exactly(a_string_matching(/B25-40, rej\. 255/))
      expect { note.to_xml }.to raise_error(DfeRb::ValidationError, /B25-40/)
    end
  end
end
