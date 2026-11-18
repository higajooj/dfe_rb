RSpec.describe DfeRb::Nfse::Declaration do
  let(:clock) { Struct.new(:now).new(Time.utc(2026, 11, 18, 14, 30)) }
  let(:dps) { service_declaration(clock: clock) }
  let(:xml) { Nokogiri::XML(dps.to_xml).tap(&:remove_namespaces!) }

  def at(path) = xml.at_xpath("/DPS/infDPS/#{path}")&.text

  it "writes a DPS the NT 009 layout takes, in homologação" do
    expect(dps.layout.name).to eq(:nt009)
    expect(dps.issues).to eq([])
    expect(dps.to_xml).to start_with(%(<DPS xmlns="http://www.sped.fazenda.gov.br/nfse" versao="1.01"><infDPS Id="DPS))
  end

  it "derives the Id, the environment, the dates, the series and the issuer type" do
    expect(dps.id).to eq("DPS#{NfseHelpers::CITY}2#{NfseHelpers::PROVIDER}00001000000000000001")
    expect(xml.at_xpath("/DPS/infDPS/@Id").value).to eq(dps.id)
    expect(at("tpAmb")).to eq("2")
    expect(at("dhEmi")).to eq("2026-11-18T10:30:00-04:00") # Campo Grande's offset
    expect(at("dCompet")).to eq("2026-11-18")
    expect(at("serie")).to eq("1")
    expect(at("tpEmit")).to eq("1")
    expect(at("verAplic")).to eq("dfe_rb #{DfeRb::VERSION}")
    expect(at("finNFSe")).to eq("0")
    expect(at("IBSCBS/indDest")).to eq("0")
  end

  it "keeps the emission time across renders, so a retry sends the same DPS" do
    first = dps.to_xml
    clock.now += 120

    expect(dps.to_xml).to eq(first)
  end

  it "fills the groups by their English names, through the levels it flattens" do
    expect(at("cLocEmi")).to eq(NfseHelpers::CITY)
    expect(at("prest/regTrib/opSimpNac")).to eq("3")
    expect(at("prest/regTrib/regApTribSN")).to eq("1")
    expect(at("toma/end/endNac/CEP")).to eq("79002000")
    expect(at("serv/locPrest/cLocPrestacao")).to eq(NfseHelpers::CITY)
    expect(at("serv/cServ/cTribNac")).to eq("010101")
    expect(at("valores/vServPrest/vServ")).to eq("1000.00")
    expect(at("valores/trib/tribMun/tribISSQN")).to eq("1")
    expect(at("valores/trib/tribMun/tpRetISSQN")).to eq("1")
    expect(at("valores/trib/totTrib/pTotTribSN")).to eq("6.00")
    expect(at("IBSCBS/valores/trib/CST")).to eq("000")
  end

  it "takes the issuing city by name, and a CNPJ or CPF told apart by length" do
    declaration = service_declaration(clock: clock, city: nil) do |d|
      d.city "Campo Grande", "MS"
      d.taker tax_id: "529.982.247-25", name: "FULANO DE TAL", address: taker_address
    end
    document = Nokogiri::XML(declaration.to_xml).tap(&:remove_namespaces!)

    expect(document.at_xpath("//cLocEmi").text).to eq(NfseHelpers::CITY)
    expect(document.at_xpath("//toma/CPF").text).to eq("52998224725")
    expect(document.at_xpath("//toma/CNPJ")).to be_nil
  end

  it "writes the approximate taxes as amounts, rates or none" do
    amounts = service_declaration(clock: clock) { |d| d.approximate_taxes federal: "100.00", state: "0", municipal: "20.00" }
    rates = service_declaration(clock: clock) { |d| d.approximate_taxes rates: {federal: "10.00", state: "0", municipal: "2.00"} }

    expect(amounts.to_xml).to include("<totTrib><vTotTrib><vTotTribFed>100.00</vTotTribFed><vTotTribEst>0.00</vTotTribEst><vTotTribMun>20.00</vTotTribMun></vTotTrib></totTrib>")
    expect(rates.to_xml).to include("<totTrib><pTotTrib><pTotTribFed>10.00</pTotTribFed><pTotTribEst>0.00</pTotTribEst><pTotTribMun>2.00</pTotTribMun></pTotTrib></totTrib>")
    expect { service_declaration { |d| d.approximate_taxes federal: "1.00" } }.to raise_error(ArgumentError, /approximate_taxes takes/)
  end

  it "informs no approximate taxes for a MEI, which gives no rate" do
    mei = service_declaration(clock: clock) do |d|
      d.provider simples: :mei, simples_regime: nil
      d.valores["trib"].delete("totTrib")
    end

    expect(mei.to_xml(strict: false)).to include("<totTrib><indTotTrib>0</indTotTrib></totTrib>")
  end

  it "writes the production layout, with finNFSe and the IBS/CBS classification where it keeps them" do
    production = service_declaration(clock: clock, layout: :v1_01)
    document = Nokogiri::XML(production.to_xml).tap(&:remove_namespaces!)

    expect(production.issues).to eq([])
    expect(document.at_xpath("/DPS/infDPS/finNFSe")).to be_nil
    expect(document.at_xpath("//IBSCBS/finNFSe").text).to eq("0")
    expect(document.at_xpath("//IBSCBS/valores/trib/gIBSCBS/CST").text).to eq("000")
    expect(DfeRb::Nfse::Declaration.new(environment: :production).layout.name).to eq(:v1_01)
  end

  it "offers each layout's names for its own deduction groups" do
    expect(service_declaration(layout: :v1_01) { |d| d.values { |v| v.deductions rate: "10.00" } }.to_xml(strict: false)).to include("<vDedRed><pDR>10.00</pDR></vDedRed>")
    expect { service_declaration { |d| d.values { |v| v.deductions rate: "10.00" } } }.to raise_error(NoMethodError, /no field "deductions"/)
    expect(service_declaration { |d| d.values { |v| v.base_adjustment rate: "10.00" } }.to_xml(strict: false)).to include("<pAjusteBCISSQN>10.00</pAjusteBCISSQN>")
  end

  it "keeps what is given, and replaces a note by its key" do
    declaration = service_declaration(clock: clock) do |d|
      d.series 2
      d.issued_at Time.new(2026, 11, 18, 9, 0, 0, "-04:00")
      d.service_date Date.new(2026, 11, 17)
      d.replaces nfse_key, reason: :other, description: "Valor do servico informado errado"
    end
    document = Nokogiri::XML(declaration.to_xml).tap(&:remove_namespaces!)

    expect(declaration.id).to end_with("00002000000000000001")
    expect(document.at_xpath("//dhEmi").text).to eq("2026-11-18T09:00:00-04:00")
    expect(document.at_xpath("//dCompet").text).to eq("2026-11-17")
    expect(document.at_xpath("//subst/chSubstda").text).to eq(nfse_key)
    expect(document.at_xpath("//subst/cMotivo").text).to eq("99")
  end

  it "reports what stops the Id, and the layout's own complaints" do
    empty = described_class.new { |d| d.number 1 }

    expect(empty.issues).to include(a_string_matching(/cannot build the DPS Id yet: fill in the issuing city/))
    expect { empty.id }.to raise_error(DfeRb::ValidationError, /E0004/)
    expect { described_class.new(layout: :v2) }.to raise_error(ArgumentError, /unknown NFS-e layout/)
  end
end
