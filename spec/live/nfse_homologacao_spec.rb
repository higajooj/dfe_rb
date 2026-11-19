# Live checks of the NFS-e against the Sistema Nacional's produção restrita (homologação).
# Off by default:
#
#   DFE_RB_LIVE=1 bundle exec rspec spec/live/nfse_homologacao_spec.rb
#
# The certificate comes from DFE_RB_PFX and DFE_RB_PFX_PASSWORD (or DFE_RB_PFX_PASSWORD_FILE),
# falling back to the git-ignored notes/cert/cert.pfx and password.txt. Nothing here touches
# production.
#
# The "protocol" examples need only a valid certificate. They check from the answers that
# the Sefin Nacional and the ADN understand what the gem sends: the JSON, the GZip, the
# layout, the RSA-SHA256 signature. A DPS of an issuer the registers don't know stops at
# them (E0084), after its schema and signature were accepted.
#
# The "lifecycle" example issues a note and cancels it. It needs an issuer registered in a
# municipality that issues through the Sefin Nacional (Client#agreement says), and a service
# code that municipality administers (Client#rates says), and is skipped without them:
#   DFE_RB_LIVE_NFSE_CITY      the issuer's municipality (IBGE code)
#   DFE_RB_LIVE_NFSE_SERVICE   the national service code (cTribNac, default 010101)
#   DFE_RB_LIVE_NFSE_NBS       its NBS item (default 115021000)
#   DFE_RB_LIVE_NFSE_SIMPLES   none, mei or me_epp (default none)
#   DFE_RB_LIVE_NFSE_IM        the municipal registration, where the CNC holds one
#
# DFE_RB_LIVE_SAVE_DIR keeps the NFS-e and the cancellation in that directory.
require "fileutils"

RSpec.describe "NFS-e against the Sistema Nacional's produção restrita", live: true do
  first_number = Integer(ENV.fetch("DFE_RB_LIVE_NUMBER", Time.now.to_i.to_s[-7..]), 10)

  def self.certificate
    @certificate ||= begin
      pfx = ENV["DFE_RB_PFX"] || File.expand_path("../../notes/cert/cert.pfx", __dir__)
      password = ENV["DFE_RB_PFX_PASSWORD"]
      password ||= File.read(ENV["DFE_RB_PFX_PASSWORD_FILE"] || File.expand_path("../../notes/cert/password.txt", __dir__)).strip
      DfeRb::Certificate.from_pkcs12(File.binread(pfx), password)
    end
  end

  around do |example|
    WebMock.allow_net_connect!
    example.run
  ensure
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  let(:certificate) { self.class.certificate }
  let(:city) { ENV.fetch("DFE_RB_LIVE_NFSE_CITY", "5208707") } # Goiânia, which issues through the Sefin Nacional
  let(:client) { DfeRb::Nfse::Client.new(certificate: certificate, city: city, timeouts: {read: 60}) }
  let(:fake_key) { "#{city}22#{certificate.cnpj}#{"1".rjust(13, "0")}2611#{"1".rjust(9, "0")}0" }

  def declaration(number)
    client.build_declaration do |dps|
      dps.number number
      dps.provider tax_id: certificate.tax_id, municipal_registration: ENV["DFE_RB_LIVE_NFSE_IM"],
        simples: ENV.fetch("DFE_RB_LIVE_NFSE_SIMPLES", "none").to_sym, special_regime: :none
      dps.provider simples_regime: :simples if ENV["DFE_RB_LIVE_NFSE_SIMPLES"] == "me_epp"
      dps.service national_code: ENV.fetch("DFE_RB_LIVE_NFSE_SERVICE", "010101"), description: "Servico de teste em producao restrita",
        city_code: city, nbs: ENV.fetch("DFE_RB_LIVE_NFSE_NBS", "115021000")
      dps.amount "100.00"
      dps.issqn :taxable
      dps.withholding :none
      if ENV["DFE_RB_LIVE_NFSE_SIMPLES"] == "mei"
        dps.approximate_taxes :not_informed
      else
        dps.approximate_taxes federal: "13.45", state: "0.00", municipal: "2.00"
        dps.ibs_cbs operation_indicator: "030101", cst: "000", class_code: "000001"
      end
    end
  end

  def save(name, xml)
    dir = ENV["DFE_RB_LIVE_SAVE_DIR"] or return
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, name), xml)
  end

  describe "protocol" do
    it "reads the municipality's agreement and rates" do
      agreement = client.agreement

      expect(agreement).to be_found
      expect(agreement).to be_national_issuer
      expect(client.rates(service: "010101")).to have_attributes(message: a_kind_of(String))
    end

    it "takes the DPS's JSON, GZip, layout and signature, and judges it by the registers" do
      result = client.issue(declaration(first_number), recover: false)

      expect(result.http_status).to be_between(200, 499)
      expect(result.errors.map(&:code)).not_to include("E1225", "E1226", "E1228", "E1229", "E1235", "E0714", "E0717", "E0718")
    end

    it "looks up a key, a DPS and the distribution" do
      expect(client.consult(fake_key).status).to eq(:not_found)
      expect(client.find(declaration(first_number + 1).id)).not_to be_found
      expect(client.issued?(declaration(first_number + 1).id)).to be(false)
      expect(client.distribute(after: 0)).to satisfy { |batch| batch.found? || batch.errors.map(&:code) == ["E2220"] }
    end

    it "takes a signed event and judges it by the note" do
      result = client.cancel(fake_key, reason: "Erro na emissao da nota de teste")

      expect(result).not_to be_registered
      expect(result.code).to eq("E1831")
    end
  end

  describe "lifecycle" do
    before { skip "set DFE_RB_LIVE_NFSE_CITY to the registered issuer's municipality" unless ENV["DFE_RB_LIVE_NFSE_CITY"] }

    it "issues a note, finds it and cancels it" do
      result = client.issue!(declaration(first_number + 2))
      save(result.filename, result.nfse_xml)

      expect(client.find(client.sign(declaration(first_number + 2))).key).to eq(result.key)
      expect(client.consult(result.key)).to be_found

      canceled = client.cancel(result.key, reason: "Nota emitida em teste de producao restrita")
      save(canceled.filename, canceled.event_xml) if canceled.registered?

      expect(canceled).to be_registered, canceled.errors.join("; ")
    end
  end
end
