RSpec.describe DfeRb::Efd::Contribuicoes::Apuracao do
  let(:month) { Date.new(2026, 10, 1) }
  let(:cnpj) { "12345678000195" }

  def file
    DfeRb::Efd::Contribuicoes::File.new.tap do |f|
      f.add "0000", cod_ver: "006", tipo_escrit: 0, dt_ini: month, dt_fin: Date.new(2026, 10, 31), nome: "EMITENTE LTDA", cnpj:, uf: "MS",
        cod_mun: "5002704", ind_ativ: 2
    end
  end

  def lines(apuracao) = apuracao.write(file).to_s.split("\r\n")

  def line(apuracao, code) = lines(apuracao).select { _1.start_with?("|#{code}|") }

  context "non-cumulative" do
    let(:pis) { described_class.new(:pis, regime: :non_cumulative, cnpj:, month:) }

    it "spends the credit left from before, then the month's, and pays the rest under the DCTF's code" do
      pis.revenue(cst: "01", rate: "1.65", revenue: 10_000, base: 9_000)
      pis.untaxed(cst: "04", nature: "003", revenue: 500, account: "3.1.1.01")
      pis.credit(cst: "50", nature: "01", base: 6_000, rate: "1.65")
      pis.carried = [{month: Date.new(2026, 8, 1), code: "101", apurado: 50, balance: 20}]

      expect(line(pis, "M210")).to eq(["|M210|01|10000,00|9000,00|0,00|0,00|9000,00|1,6500|||148,50|0,00|0,00|0,00|0,00|148,50|"])
      expect(line(pis, "M100")).to eq(["|M100|101|0|6000,00|1,6500|||99,00|0,00|0,00|0,00|99,00|0|99,00|0,00|"])
      expect(line(pis, "M105")).to eq(["|M105|01|50|6000,00|0,00|6000,00|6000,00||||"])
      expect(line(pis, "M200")).to eq(["|M200|148,50|99,00|20,00|29,50|0,00|0,00|29,50|0,00|0,00|0,00|0,00|29,50|"])
      expect(line(pis, "M205")).to eq(["|M205|08|691201|29,50|"])
      expect(line(pis, "M400")).to eq(["|M400|04|500,00|3.1.1.01||"])
      expect(line(pis, "M410")).to eq(["|M410|003|500,00|3.1.1.01||"])
      expect(line(pis, "1100")).to eq(["|1100|082026|01||101|50,00|0,00|50,00|30,00|||20,00|20,00|||||0,00|"])
      expect(pis.carry).to be_empty
      expect(pis.payable).to eq(BigDecimal("29.5"))
    end

    it "carries the month's credit left over in its own 1100" do
      pis.revenue(cst: "01", rate: "1.65", revenue: 1_000, base: 1_000)
      pis.credit(cst: "50", nature: "01", base: 6_000, rate: "1.65")

      expect(line(pis, "M100").first).to eq("|M100|101|0|6000,00|1,6500|||99,00|0,00|0,00|0,00|99,00|1|16,50|82,50|")
      expect(line(pis, "M200").first).to start_with("|M200|16,50|16,50|0,00|0,00|0,00|0,00|0,00|")
      expect(line(pis, "M205")).to be_empty
      expect(line(pis, "1100")).to eq(["|1100|102026|01||101|99,00|0,00|99,00|16,50|||82,50|0,00|||||82,50|"])
      expect(pis.carry).to eq([{month:, code: "101", apurado: BigDecimal(99), balance: BigDecimal("82.5")}])
    end

    it "splits a credit common to taxed and untaxed revenue by the month's revenue of each" do
      cofins = described_class.new(:cofins, regime: :non_cumulative, cnpj:, month:, shares: {taxed: 750, untaxed: 250, export: 0})
      cofins.credit(cst: "53", nature: "01", base: 1_000, rate: "7.6")

      expect(line(cofins, "M500")).to eq(["|M500|101|0|750,00|7,6000|||57,00|0,00|0,00|0,00|57,00|1|0,00|57,00|",
        "|M500|201|0|250,00|7,6000|||19,00|0,00|0,00|0,00|19,00|1|0,00|19,00|"])
      expect(line(cofins, "M505")).to eq(["|M505|01|53|1000,00|0,00|1000,00|750,00||||", "|M505|01|53|1000,00|0,00|1000,00|250,00||||"])
      expect(line(cofins, "1500").map { _1.split("|")[5] }).to eq(%w[101 201])
    end

    it "takes back a credit returned, and adds what the month's credit doesn't cover to the contribution" do
      pis.credit(cst: "50", nature: "01", base: 1_000, rate: "1.65")
      pis.reduce_credit(type: "101", amount: 20, document: "88", description: "Devolução de compra", date: Date.new(2026, 10, 9))

      expect(line(pis, "M100").first).to eq("|M100|101|0|1000,00|1,6500|||16,50|0,00|16,50|0,00|0,00|0|0,00|0,00|")
      expect(line(pis, "M110").first).to eq("|M110|0|16,50|06|88|Devolução de compra|09102026|")
      expect(line(pis, "M210").first).to eq("|M210|01|0,00|0,00|0,00|0,00|0,00|1,6500|||0,00|3,50|0,00|0,00|0,00|3,50|")
      expect(line(pis, "M220").first).to eq("|M220|1|3,50|06|88|Devolução de compra|09102026|")
      expect(line(pis, "M205").first).to eq("|M205|08|691201|3,50|")
    end
  end

  context "cumulative" do
    it "reduces the base by the sales given back and pays the COFINS under its own registers" do
      cofins = described_class.new(:cofins, regime: :cumulative, cnpj:, month:)
      cofins.revenue(cst: "01", rate: 3, revenue: 1_000, base: 1_000)
      cofins.reduce_base(cst: "01", rate: 3, amount: 200, code: "02", document: "55", description: "Devolução", date: Date.new(2026, 10, 3))
      cofins.reduce_base(cst: "01", rate: 3, amount: 900, code: "02", document: "56")

      expect(line(cofins, "M610")).to eq(["|M610|51|1000,00|1000,00|0,00|1000,00|0,00|3,0000|||0,00|0,00|0,00|0,00|0,00|0,00|"])
      expect(line(cofins, "M615")).to eq(["|M615|0|200,00|02|55|Devolução|03102026||#{cnpj}||", "|M615|0|800,00|02|56||||#{cnpj}||"])
      expect(line(cofins, "M600").first).to eq("|M600|0,00|0,00|0,00|0,00|0,00|0,00|0,00|0,00|0,00|0,00|0,00|0,00|")
    end

    it "pays the contribution of the basic rate as 51, field 12 of M200" do
      pis = described_class.new(:pis, regime: :cumulative, cnpj:, month:)
      pis.revenue(cst: "01", rate: "0.65", revenue: 1_000, base: 1_000)

      expect(line(pis, "M210").first).to start_with("|M210|51|1000,00|1000,00|0,00|0,00|1000,00|0,6500|||6,50|")
      expect(line(pis, "M205")).to eq(["|M205|12|810902|6,50|"])
      expect(line(pis, "M100")).to be_empty
    end
  end

  it "books a revenue by ST (CST 05) as contribution 31, even at a zero rate, never among the revenues without it" do
    pis = described_class.new(:pis, regime: :cumulative, cnpj:, month:)
    pis.revenue(cst: "05", rate: 0, revenue: 300, base: 0)

    expect(line(pis, "M210")).to eq(["|M210|31|300,00|0,00|0,00|0,00|0,00|0,0000|||0,00|0,00|0,00|0,00|0,00|0,00|"])
    expect(line(pis, "M400")).to be_empty
    expect { pis.untaxed(cst: "05", nature: "999", revenue: 1) }.to raise_error(ArgumentError, /05/)
  end

  it "splits a credit taken back that went with more than one revenue by the month's shares" do
    pis = described_class.new(:pis, regime: :non_cumulative, cnpj:, month:, shares: {taxed: 300, untaxed: 100})
    pis.credit(cst: "53", nature: "01", base: 4_000, rate: "1.65")
    pis.reduce_credit(cst: "53", rate: "1.65", amount: 10, document: "9")

    expect(line(pis, "M110").map { _1.split("|")[3] }).to eq(%w[7,50 2,50])
    expect(line(pis, "M100").map { _1.split("|").values_at(2, 10) }).to eq([%w[101 7,50], %w[201 2,50]])
    expect { pis.reduce_credit(cst: "70", amount: 1) }.to raise_error(ArgumentError)
  end

  it "refuses what isn't a contribution, a credit or a revenue without the contribution" do
    expect { described_class.new(:icms, regime: :cumulative, cnpj:, month:) }.to raise_error(ArgumentError)
    pis = described_class.new(:pis, regime: :non_cumulative, cnpj:, month:)
    expect { pis.credit(cst: "70", nature: "01", base: 1, rate: 1) }.to raise_error(ArgumentError, /70/)
    expect { pis.untaxed(cst: "01", nature: "001", revenue: 1) }.to raise_error(ArgumentError, /01/)
  end
end
