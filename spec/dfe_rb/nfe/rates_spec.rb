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
end
