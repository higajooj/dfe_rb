RSpec.describe DfeRb::AccessKey do
  let(:parts) { {state: "MS", issued_at: Time.new(2026, 10, 12), tax_id: "11.444.777/0001-61", series: 1, number: 42, numeric_code: "00098765"} }

  it "builds the key of any DF-e model, with the Id its signed element takes" do
    key = described_class.build(model: 58, **parts)

    expect(key.to_s).to match(/\A5026101144477700016158001000000042100098765\d\z/)
    expect(key).to have_attributes(model: 58, state: "MS", series: 1, number: 42)
    expect(key.id).to eq("MDFe#{key}")
    expect(described_class.parse(key.to_s)).to eq(key)
  end

  it "wants the model named" do
    expect { described_class.build(**parts) }.to raise_error(ArgumentError, /model/)
  end

  it "knows no Id for a model it has no prefix for" do
    expect { described_class.build(model: 67, **parts).id }.to raise_error(ArgumentError, /model 67/)
  end

  it "is the NF-e's key with the NF-e defaults" do
    key = DfeRb::Nfe::AccessKey.build(**parts)

    expect(key).to be_a(described_class).and have_attributes(model: 55, id: "NFe#{key}")
    expect(key).to eq(described_class.parse(key.to_s))
  end
end
