RSpec.describe DfeRb::Nfe::Rates do
  describe ".interstate" do
    it "is 7% from the South/Southeast to the other regions and Espírito Santo, 12% otherwise" do
      expect(described_class.interstate("SP", "BA", 0)).to eq(7)
      expect(described_class.interstate("PR", "ES", 0)).to eq(7)
      expect(described_class.interstate("SP", "RJ", 0)).to eq(12)
      expect(described_class.interstate("ES", "SP", 0)).to eq(12)
      expect(described_class.interstate("BA", "PE", 0)).to eq(12)
    end

    it "is 4% for imported goods" do
      expect(%w[1 2 3 8].map { |origin| described_class.interstate("SP", "BA", origin) }).to all(eq(4))
      expect(described_class.interstate("SP", "BA", 5)).to eq(7)
    end

    it "is nil within a state or abroad" do
      expect(described_class.interstate("SP", "SP", 0)).to be_nil
      expect(described_class.interstate("SP", "EX", 0)).to be_nil
    end
  end

  it "gives the DIFAL partition of each year" do
    expect([2015, 2016, 2017, 2018, 2019, 2026].map { |year| described_class.partition(year)&.to_i }).to eq([nil, 40, 60, 80, 100, 100])
  end

  it "gives the IBS/CBS standard rates the law fixes (IT 2025.002)" do
    expect(described_class.ibs_cbs(2026).transform_values { |rate| rate.to_s("F") }).to eq(uf: "0.1", municipal: "0.0", cbs: "0.9")
    expect(described_class.ibs_cbs(2027)[:cbs]).to be_nil
    expect(described_class.ibs_cbs(2030)).to eq({})
  end

  describe ".adjusted_mva" do
    it "adjusts the margin for an interstate rate below the internal one (Conv. ICMS 142/2018)" do
      adjusted = [4, 7, 12].map { |rate| described_class.adjusted_mva("50.00", interstate: rate, internal: "17.00").to_s("F") }

      expect(adjusted).to eq(%w[73.49 68.07 59.04])
    end

    it "keeps the original margin without an interstate rate or when it isn't below the internal one" do
      expect(described_class.adjusted_mva(50, interstate: nil, internal: 17)).to eq(50)
      expect(described_class.adjusted_mva(50, interstate: 12, internal: 12)).to eq(50)
    end
  end

  it "gives the PIS and COFINS rates of each regime" do
    expect(described_class.pis_cofins(:cumulative).transform_values { |rate| rate.to_s("F") }).to eq(pis: "0.65", cofins: "3.0")
    expect(described_class.pis_cofins("non_cumulative").transform_values { |rate| rate.to_s("F") }).to eq(pis: "1.65", cofins: "7.6")
    expect { described_class.pis_cofins(:presumed) }.to raise_error(ArgumentError, /cumulative, non_cumulative/)
  end

  describe ".simples_icms_credit" do
    it "is the effective rate of the bracket times the ICMS share (LC 123/2006, art. 23)" do
      # 4% x 34%
      expect(described_class.simples_icms_credit(revenue_12m: 180_000).to_s("F")).to eq("1.36")
      # (1,000,000 x 10.7% - 22,500) / 1,000,000 = 8.45% x 33.5%
      expect(described_class.simples_icms_credit(revenue_12m: "1000000.00").to_s("F")).to eq("2.83")
      # (1,000,000 x 11.2% - 22,500) / 1,000,000 = 8.95% x 32%
      expect(described_class.simples_icms_credit(revenue_12m: 1_000_000, annex: :industry).to_s("F")).to eq("2.86")
    end

    it "is nil without revenue and above the ICMS sublimit" do
      expect(described_class.simples_icms_credit(revenue_12m: 0)).to be_nil
      expect(described_class.simples_icms_credit(revenue_12m: 3_600_000.01)).to be_nil
      expect(described_class.simples_icms_credit(revenue_12m: 5_000_000)).to be_nil
    end
  end
end
