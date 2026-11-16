RSpec.describe DfeRb::Nfe::Retirements do
  def at(year, month, day, hour = 0, minute = 0, second = 0) = Time.new(year, month, day, hour, minute, second, "-03:00")

  describe ".inutilization_off? (RV I01a, NT 2023.002 v1.02)" do
    it "is true for AC, BA and SP from 11/11/2026, in any spelling of the state" do
      expect(%w[AC BA SP ac 35 29].map { |uf| described_class.inutilization_off?(uf, at(2026, 11, 11)) }).to all(be(true))
    end

    it "is false the instant before, and for every other state" do
      expect(described_class.inutilization_off?("SP", at(2026, 11, 10, 23, 59, 59))).to be(false)
      others = DfeRb::States::CODES.keys - %w[AC BA SP]
      expect(others.map { |uf| described_class.inutilization_off?(uf, at(2027, 1, 1)) }).to all(be(false))
    end
  end

  describe ".async_lot_ended?" do
    it "is homologação's day, 01/02/2027, or production's, 05/04/2027, for the clock or any dhEmi" do
      expect(described_class.async_lot_ended?(:homologacao, [at(2027, 1, 31, 23, 59, 59)])).to be(false)
      expect(described_class.async_lot_ended?(:homologacao, [at(2027, 2, 1)])).to be(true)
      expect(described_class.async_lot_ended?(:production, [at(2027, 4, 4, 23, 59, 59)])).to be(false)
      expect(described_class.async_lot_ended?(:production, [at(2027, 4, 5)])).to be(true)
      expect(described_class.async_lot_ended?(:production, [at(2027, 1, 1), nil, at(2027, 4, 6)])).to be(true)
      expect(described_class.async_lot_ended?("1", [at(2027, 4, 1)])).to be(false)
    end
  end
end
