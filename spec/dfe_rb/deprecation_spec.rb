RSpec.describe DfeRb::Deprecation do
  # The suite silences the notices before each example; these examples want them.
  before { described_class.silenced = false }

  it "writes a notice once per id, to $stderr, led by the gem's name" do
    expect { described_class.warn(:old, "it goes away") }.to output("[dfe_rb] DEPRECATION: it goes away\n").to_stderr
    expect { described_class.warn(:old, "it goes away") }.not_to output.to_stderr
    expect { described_class.warn(:other, "so does this") }.to output(/so does this/).to_stderr
  end

  it "writes each notice again after #reset!" do
    expect { described_class.warn(:old, "it goes away") }.to output(/it goes away/).to_stderr
    described_class.reset!

    expect { described_class.warn(:old, "it goes away") }.to output(/it goes away/).to_stderr
  end

  it "writes nothing while silenced" do
    described_class.silenced = true

    expect { described_class.warn(:old, "it goes away") }.not_to output.to_stderr
  end

  describe "the asynchronous lot and the receipt query (RV GAP03a-6, NT 2023.002 v1.02)" do
    let(:transport) { NfeHelpers::FakeTransport.new }
    let(:clock) { Struct.new(:now).new(Time.new(2026, 11, 16, 10, 0, 0, "-03:00")) }
    let(:client) { nfe_client(transport, clock: clock) }
    let(:notes) { [1, 2].map { |number| client.sign(simples_invoice(client, number: number)) } }

    before do
      transport.answer(:authorization, ret_env_nfe)
      transport.answer(:authorization_return, ->(_xml) { ret_cons_reci_nfe(notes.map { |note| prot_nfe(note.key) }) })
    end

    it "warns once that the lot is rejected from the day SEFAZ sets, and still sends it" do
      expect { client.authorize(notes) }.to output(
        /DEPRECATION: an asynchronous authorization lot .* rejected from 01\/02\/2027 in homologacao \(RV GAP03a-6, rej\. 129, NT 2023\.002 v1\.02\)/
      ).to_stderr
      expect { client.authorize(notes) }.not_to output.to_stderr
      expect(transport.calls_to(:authorization).size).to eq(2)
    end

    it "gives production's day in production" do
      production = nfe_client(transport, clock: clock, environment: :production)
      lot = [1, 2].map { |number| production.sign(simples_invoice(production, number: number)) }

      expect { production.authorize(lot) }.to output(/rejected from 05\/04\/2027 in production/).to_stderr
    end

    it "warns nothing for a note sent on its own" do
      transport.replace(:authorization, ret_env_nfe_sync(prot_nfe(notes.first.key)))

      expect { client.authorize(notes.first) }.not_to output.to_stderr
    end

    it "warns that the receipt query goes with the lot when #resume is called" do
      expect { client.resume("351000000012345", notes) }.to output(
        /DEPRECATION: Nfe::Client#resume and the receipt query \(consReciNFe\) go with the asynchronous authorization lot/
      ).to_stderr
    end

    it "refuses the lot with an error, not a notice, once it is rejected" do
      later = nfe_client(transport, clock: Struct.new(:now).new(Time.new(2027, 2, 1, 0, 0, 0, "-03:00")))

      expect {
        expect { later.authorize(notes) }.to raise_error(DfeRb::ValidationError, /rej\. 129/)
      }.not_to output.to_stderr
    end
  end
end
