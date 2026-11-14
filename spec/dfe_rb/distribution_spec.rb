RSpec.describe DfeRb::Distribution do
  it "tells what a cStat kept on its own means" do
    expect([138, 137, 656, 678, 108, 109].map { |code| described_class.status(code) })
      .to eq(%i[documents empty blocked blocked unavailable unavailable])
    expect(%w[280 287 593 472 491 492].map { |code| described_class.status(code) }).to all(eq(:certificate))
    expect([215, 489, 589, 9999, nil].map { |code| described_class.status(code) }).to all(eq(:rejected))
  end
end
