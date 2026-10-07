# Opt-in checks against the national distribution service. Run them with DFE_RB_LIVE=1 and
# the certificate variables the README documents. They send no production requests and never
# poll or retry.
RSpec.describe "NF-e distribution against SEFAZ homologacao", live: true do
  let(:certificate) do
    pfx = ENV["DFE_RB_PFX"] || File.expand_path("../../notes/cert/cert.pfx", __dir__)
    password = ENV["DFE_RB_PFX_PASSWORD"]
    password ||= File.read(ENV["DFE_RB_PFX_PASSWORD_FILE"] || File.expand_path("../../notes/cert/password.txt", __dir__)).strip
    DfeRb::Certificate.from_pkcs12(File.binread(pfx), password)
  end
  let(:client) { DfeRb::Nfe::Distribution::Client.new(certificate: certificate, timeouts: {read: 60}) }

  around do |example|
    WebMock.allow_net_connect!
    example.run
  ensure
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  it "understands sequential distribution, including a pre-existing cooldown" do
    result = client.distribute(after: ENV.fetch("DFE_RB_LIVE_LAST_NSU", "0"))
    expect([137, 138, 656]).to include(result.code), "#{result.code} #{result.message}"
    expect(result.environment).to eq(:homologacao)
    expect(result.documents).to all(respond_to(:xml))
  end

  it "understands both targeted-query contracts" do
    nsu = client.fetch_nsu(ENV.fetch("DFE_RB_LIVE_NSU", "1"))
    expect([137, 138, 589, 656]).to include(nsu.code), "#{nsu.code} #{nsu.message}"
    key = ENV["DFE_RB_LIVE_DISTRIBUTION_KEY"] || test_key(999_995)
    result = client.fetch_key(key)
    expect([137, 138, 217, 656]).to include(result.code), "#{result.code} #{result.message}"
  end

  it "understands a mixed batch of all four signed manifestation types" do
    events = DfeRb::Nfe::Distribution::Manifestations::TYPES.keys.each_with_index.map do |type, index|
      reason = (type == :not_performed) ? "Teste de operacao nao realizada em homologacao" : nil
      client.prepare_manifestation(test_key(999_990 + index), type: type, reason: reason)
    end
    results = client.manifest(events)
    # Unknown keys can be registered without linkage (136) or rejected by the national
    # database (494). What matters here is a business answer, not a SOAP/schema failure.
    expect(results.size).to eq(4)
    results.each do |result|
      expect([135, 136, 494, 573, 575]).to include(result.code), "#{result.code} #{result.message}"
    end
  end

  def test_key(number)
    DfeRb::Nfe::AccessKey.build(state: ENV.fetch("DFE_RB_LIVE_UF", "SP"), issued_at: Time.now,
      tax_id: certificate.tax_id, series: 1, number: number, numeric_code: "87654321").to_s
  end
end
