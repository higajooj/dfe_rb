RSpec.describe DfeRb::Nfe::Tables do
  it "names a city by its IBGE code" do
    expect(described_class.city_name("5002704")).to eq("Campo Grande")
    expect(described_class.city_name("5101837")).to eq("Boa Esperança do Norte")
    expect(described_class.city_name("9999999")).to be_nil
  end

  it "finds a city's code by name within its state, ignoring case and accents" do
    expect(described_class.city_code("sao paulo", "SP")).to eq("3550308")
    expect(described_class.city_code("BOA ESPERANCA DO NORTE", "MT")).to eq("5101837")
    expect(described_class.city_code("Campo Grande", "AL")).to eq("2701506")
    expect(described_class.city_code("Campo Grande", "PB")).to be_nil
    expect(described_class.city_code("Campo Grande", "XX")).to be_nil
  end

  it "describes a tax classification" do
    food = described_class.classification("200034")

    expect([food.cst, food.ibs_reduction.to_i, food.cbs_reduction.to_i]).to eq(["200", 60, 60])
    expect([food.taxed?, food.rate_reduction?, food.monophase?, food.deferral?, food.regular_taxation?]).to eq([true, true, false, false, false])
    expect(described_class.classification("410001").taxed?).to be(false)
    expect(described_class.classification("510001").deferral?).to be(true)
    expect(described_class.classification("550001").regular_taxation?).to be(true)
    expect(described_class.classification("999999")).to be_nil
  end

  it "describes a CFOP by the indicators of IT 2023.002" do
    purchase = described_class.cfop("1102")

    expect([purchase.title, purchase.valid_from, purchase.valid_until]).to eq(["Compra para comercialização.", "2006-01-01", nil])
    expect(purchase.nfe?).to be(true)
    expect(%i[communication? transport? devolution? goods_return? annulment? remittance? fuel? ibs_cbs_only?].map { |flag| purchase.public_send(flag) }).to all(be(false))
    expect(described_class.cfop("6916")).to have_attributes(goods_return?: true, ibs_cbs_only?: true)
    expect(described_class.cfop("5205").annulment?).to be(true)
    expect(described_class.cfop("5301")).to have_attributes(nfe?: false, communication?: true)
    expect(described_class.cfop("1652")).to have_attributes(fuel?: true, fuel: 2)
    expect(described_class.cfop(6551).ibs_cbs_only?).to be(true)
    expect(described_class.cfop("9999")).to be_nil
  end

  it "finds a CFOP however its code is written" do
    expect(["5102", "5.102", 5102].map { |code| described_class.cfop(code)&.code }).to eq(%w[5102 5102 5102])
  end

  it "tells a CFOP's direction, scope and validity" do
    expect(described_class.cfop("1102")).to have_attributes(entry?: true, exit?: false, scope: :internal)
    expect(described_class.cfop("6916")).to have_attributes(entry?: false, exit?: true, scope: :interstate)
    expect(described_class.cfop("7101").scope).to eq(:foreign)

    onboard = described_class.cfop("3552")   # in force since 01/06/2021
    expect([onboard.valid_on?("2021-05-31"), onboard.valid_on?(Date.new(2021, 6, 1)), onboard.valid_on?]).to eq([false, true, true])
  end

  it "lists every CFOP, or those matching a text and a code prefix" do
    expect(described_class.cfops.size).to eq(619)
    expect(described_class.cfops.map(&:code)).to eq(described_class.cfops.map(&:code).sort)
    expect(described_class.cfops(matching: "remessa CONSERTO").map(&:code)).to eq(%w[5915 6915])
    expect(described_class.cfops(matching: "6.9 retorno conserto").map(&:code)).to eq(%w[6916])
    expect(described_class.cfops(matching: "combustiveis").map(&:code)).to include("5656", "6656")
    expect(described_class.cfops(matching: "nada parecido")).to eq([])
  end
end
