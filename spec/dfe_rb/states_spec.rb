RSpec.describe DfeRb::States do
  it "looks a state up by abbreviation or IBGE code" do
    expect(described_class.abbreviation(" ms ")).to eq("MS")
    expect(described_class.abbreviation(50)).to eq("MS")
    expect(described_class.code("MS")).to eq("50")
    expect { described_class.abbreviation("XX") }.to raise_error(ArgumentError, /unknown state/)
  end

  it "tells the time in the state's offset" do
    clock = class_double(Time, now: Time.utc(2026, 10, 12, 15))

    expect(described_class.now("MS", clock).iso8601).to eq("2026-10-12T11:00:00-04:00")
    expect(described_class.now("SP", clock).iso8601).to eq("2026-10-12T12:00:00-03:00")
  end

  it "is part of the NF-e's states, which add the authorizers" do
    expect(DfeRb::Nfe::States::CODES).to equal(described_class::CODES)
    expect(DfeRb::Nfe::States.code("MS")).to eq("50")
    expect(DfeRb::Nfe::States.authorizer("MS")).to eq("MS")
    expect(described_class).not_to respond_to(:authorizer)
  end
end
