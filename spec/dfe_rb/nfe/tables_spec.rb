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

    # Fim de vigência is the first day the code is no longer accepted (IT 2023.002).
    retired = onboard.dup.tap { |row| row.valid_until = "2026-10-02" }
    expect([retired.valid_on?("2026-10-01"), retired.valid_on?("2026-10-02")]).to eq([true, false])
  end

  it "lists every CFOP, or those matching a text and a code prefix" do
    expect(described_class.cfops.size).to eq(619)
    expect(described_class.cfops.map(&:code)).to eq(described_class.cfops.map(&:code).sort)
    expect(described_class.cfops(matching: "remessa CONSERTO").map(&:code)).to eq(%w[5915 6915])
    expect(described_class.cfops(matching: "6.9 retorno conserto").map(&:code)).to eq(%w[6916])
    expect(described_class.cfops(matching: "combustiveis").map(&:code)).to include("5656", "6656")
    expect(described_class.cfops(matching: "nada parecido")).to eq([])
  end

  it "gives the TIPI's IPI rate of an NCM and of its EX" do
    beer = described_class.ipi_rate("2203.00.00")

    expect([beer.ncm, beer.ex, beer.rate.to_s("F"), beer.non_taxed?]).to eq(["22030000", nil, "3.9", false])
    expect(described_class.ipi_rate("03057100").rate).to eq(0)
    expect(%w[1 01 001].map { |ex| described_class.ipi_rate("03057100", ex).rate.to_s("F") }).to eq(%w[3.25 3.25 3.25])
    expect(described_class.ipi_rate("03057100", "99").ex).to be_nil   # an EX the TIPI lacks: the NCM's own line
    expect(described_class.ipi_rate("02109100", 1)).to have_attributes(non_taxed?: true, rate: nil)
    expect(described_class.ipi_rate("99999999")).to be_nil
    expect(described_class.ipi_rates.size).to eq(11_107)
  end

  it "describes a payment method and the day it starts" do
    automatic = described_class.payment_method(23)

    expect([automatic.code, automatic.title, automatic.valid_from]).to eq(["23", "Pagamento Instantâneo (PIX) - Automático", "2026-05-04"])
    expect([automatic.valid_on?("2026-05-03"), automatic.valid_on?(Date.new(2026, 5, 4))]).to eq([false, true])
    expect(described_class.payment_method("01")).to have_attributes(valid_from: nil, deferred?: false, valid_on?: true)
    # IT 2024.002 renamed 05 and 17, which the table already had.
    expect(%w[05 17].map { |code| described_class.payment_method(code).valid_on?("2023-01-01") }).to eq([true, true])
    expect(described_class.payment_method("20").valid_on?("2024-06-30")).to be(false)
    expect(described_class.payment_methods.select(&:deferred?).map(&:code)).to eq(%w[90 91])
    expect(described_class.payment_method("06")).to be_nil
    expect(DfeRb::Nfe::Names::ENUMS["tPag"].values - described_class.payment_methods.map(&:code)).to eq([])
  end

  it "names the card brands" do
    expect(described_class.card_brands.values_at("01", "06", "99")).to eq(%w[Visa Elo Outros])
    expect(described_class.card_brands.size).to eq(28)
  end
end
