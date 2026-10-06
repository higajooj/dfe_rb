RSpec.describe DfeRb::Nfe::Apportion do
  def shares(amount, weights) = described_class.call(amount, weights).map { |share| share.to_s("F") }

  it "splits in proportion to the weights, to the cent" do
    expect(shares("10.00", %w[100 200])).to eq(%w[3.33 6.67])
    expect(shares("0.05", %w[1 1 1])).to eq(%w[0.02 0.02 0.01])
    expect(shares("100.00", %w[50])).to eq(%w[100.0])
  end

  it "always adds up to the amount" do
    result = described_class.call("1000.01", %w[33.33 33.33 33.34 0.01 977.77])

    expect(result.sum.to_s("F")).to eq("1000.01")
  end

  it "splits evenly when nothing has a value" do
    expect(shares("1.00", %w[0 0])).to eq(%w[0.5 0.5])
    expect(described_class.call("1.00", [])).to eq([])
  end

  it "leaves out the items that set the value themselves, and the zero shares" do
    det = [{"prod" => {"vProd" => "100.00", "vFrete" => "9.00"}}, {"prod" => {"vProd" => "0.01"}}, {"prod" => {"vProd" => "500.00"}}]
    described_class.apply(det, "vFrete" => "1.00")

    expect(det.map { |item| item["prod"]["vFrete"]&.to_s }).to eq(["9.00", nil, "0.1e1"])
  end
end
