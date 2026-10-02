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
end
