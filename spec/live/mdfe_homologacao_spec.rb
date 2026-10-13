# Live checks of the MDF-e against the real SEFAZ homologacao environment (SVRS). Off by default:
#
#   DFE_RB_LIVE=1 bundle exec rspec spec/live/mdfe_homologacao_spec.rb
#
# The certificate comes from DFE_RB_PFX and DFE_RB_PFX_PASSWORD (or DFE_RB_PFX_PASSWORD_FILE),
# falling back to the git-ignored notes/cert/cert.pfx and password.txt. Nothing here touches
# production.
#
# The "protocol" examples need only a valid certificate. They check from SEFAZ's answers that
# it understands what the gem sends (SOAP contract, compression, signatures, schemas).
#
# The "lifecycle" examples need an issuer accredited for the MDF-e in its state, and are
# skipped without one:
#   DFE_RB_LIVE_UF and DFE_RB_LIVE_IE
#   DFE_RB_LIVE_CITY_CODE and _ZIP (and optionally _NAME, _STREET, _STREET_NUMBER, _DISTRICT)
#   DFE_RB_LIVE_PLATE, a vehicle with no manifest left open (default ABC1D23)
#   DFE_RB_LIVE_NFE_KEY, the NF-e to carry (default: a made-up key of the issuer's, which
#     homologacao doesn't look up)
#
# DFE_RB_LIVE_SAVE_DIR keeps what SEFAZ registered (each mdfeProc and procEventoMDFe) in that
# directory, the manifest before its cancellation or closing.
require "fileutils"

RSpec.describe "MDF-e against SEFAZ homologacao", live: true do
  # Each run numbers its manifests anew (from DFE_RB_LIVE_NUMBER or the clock), read once so
  # that the examples don't land on each other's numbers.
  first_number = Integer(ENV.fetch("DFE_RB_LIVE_NUMBER", Time.now.to_i.to_s[-7..]), 10)

  def self.certificate
    @certificate ||= begin
      pfx = ENV["DFE_RB_PFX"] || File.expand_path("../../notes/cert/cert.pfx", __dir__)
      password = ENV["DFE_RB_PFX_PASSWORD"]
      password ||= File.read(ENV["DFE_RB_PFX_PASSWORD_FILE"] || File.expand_path("../../notes/cert/password.txt", __dir__)).strip
      DfeRb::Certificate.from_pkcs12(File.binread(pfx), password)
    end
  end

  # The default suite forbids real connections; these examples exist to make them.
  around do |example|
    WebMock.allow_net_connect!
    example.run
  ensure
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  let(:certificate) { self.class.certificate }
  let(:number) { first_number }
  let(:uf) { ENV.fetch("DFE_RB_LIVE_UF", "SP") }
  let(:client) { DfeRb::Mdfe::Client.new(certificate: certificate, uf: uf, timeouts: {read: 60}) }
  let(:city_code) { ENV.fetch("DFE_RB_LIVE_CITY_CODE", "3550308") }
  let(:issuer) do
    {
      tax_id: certificate.tax_id, name: ENV.fetch("DFE_RB_LIVE_NAME", "EMPRESA DE TESTE LTDA"),
      state_registration: ENV.fetch("DFE_RB_LIVE_IE", "111111111111"),
      address: {street: ENV.fetch("DFE_RB_LIVE_STREET", "Rua Teste"), number: ENV.fetch("DFE_RB_LIVE_STREET_NUMBER", "100"),
                district: ENV.fetch("DFE_RB_LIVE_DISTRICT", "Centro"), city_code: city_code, zip: ENV.fetch("DFE_RB_LIVE_ZIP", "01001000")}
    }
  end
  let(:nfe_key) do
    ENV.fetch("DFE_RB_LIVE_NFE_KEY") do
      DfeRb::AccessKey.build(state: uf, issued_at: Time.now, tax_id: certificate.tax_id, series: 1, number: 999_997,
        numeric_code: "87654321", model: 55).to_s
    end
  end
  let(:unknown_key) do
    DfeRb::Mdfe::AccessKey.build(state: uf, issued_at: Time.now, tax_id: certificate.tax_id, series: 1, number: 999_999, numeric_code: "87654321").to_s
  end

  def save(result)
    return result unless ENV["DFE_RB_LIVE_SAVE_DIR"] && result.proc_xml

    FileUtils.mkdir_p(ENV["DFE_RB_LIVE_SAVE_DIR"])
    File.write(File.join(ENV["DFE_RB_LIVE_SAVE_DIR"], result.filename), result.proc_xml)
    result
  end

  def manifest(number:, nfe:, &block)
    client.build_manifest do |mdfe|
      mdfe.series certificate.cnpj ? 1 : 920
      mdfe.number number
      mdfe.issuer_type :own_cargo
      mdfe.issuer(**issuer)
      mdfe.load_at city_code
      mdfe.unload_at city_code, nfe: [nfe]
      mdfe.road do |road|
        road.vehicle plate: ENV.fetch("DFE_RB_LIVE_PLATE", "ABC1D23"), tare: 9000, wheels: :truck, body: :closed, state: uf do |vehicle|
          vehicle.driver "MOTORISTA DE TESTE", "12345678909"
        end
      end
      mdfe.cargo value: "100.00", weight: "10"
      block&.call(mdfe)
    end
  end

  describe "protocol" do
    it "finds the authorizer in service" do
      status = client.status

      expect(status).to be_online, "#{status.code} #{status.message}"
    end

    it "understands a consult, answering that the key is unknown" do
      expect(client.consult(unknown_key).status).to eq(:not_found)
    end

    it "lists the manifests the certificate's holder left open" do
      result = client.unclosed

      # 203: the holder isn't accredited for the MDF-e, which is a business answer too.
      expect([111, 112, 203]).to include(result.code), "#{result.code} #{result.message}"
    end

    it "accepts a compressed, signed, schema-valid MDFe and answers with a business verdict" do
      result = save(client.authorize(manifest(number: number, nfe: nfe_key), recover: false))
      # An accredited issuer gets it authorized: cancel it, so the vehicle isn't left on a trip.
      save(client.cancel(result.key, protocol: result.protocol, reason: "Teste de cancelamento em homologacao")) if result.code == 100

      # Not a compression (2xx B-0), schema (215, 580), signature (29x) or QR code (48x)
      # problem: the issuer's registration or the NF-e it can't find.
      expect([100, 203, 207, 209, 229, 230, 231, 232, 233, 247, 611, 675, 686]).to include(result.code), "#{result.code} #{result.message}"
    end

    it "understands every event, answering about the missing manifest or issuer" do
      protocol = "935260000000001"
      results = [
        client.cancel(unknown_key, protocol: protocol, reason: "Teste de cancelamento em homologacao"),
        client.close(unknown_key, protocol: protocol, city: city_code),
        client.add_driver(unknown_key, name: "MOTORISTA DE TESTE", cpf: "12345678909"),
        client.add_documents(unknown_key, protocol: protocol, load_at: city_code,
          documents: [{nfe: DfeRb::AccessKey.build(state: uf, issued_at: Time.now, tax_id: certificate.tax_id, series: 1, number: 999_996,
            numeric_code: "87654321", model: 55).to_s, unload_at: city_code}])
      ]

      # 217: no such manifest. 203: issuer not accredited. Not 215/630 (schema) or 29x (signature).
      results.each { |result| expect([203, 217]).to include(result.code), "#{result.type}: #{result.code} #{result.message}" }
    end

    it "understands distribution, including a pre-existing cooldown" do
      result = DfeRb::Mdfe::Distribution::Client.new(certificate: certificate, timeouts: {read: 60})
        .distribute(after: ENV.fetch("DFE_RB_LIVE_MDFE_LAST_NSU", "0"))

      expect([137, 138, 678]).to include(result.code), "#{result.code} #{result.message}"
      expect(result.documents).to all(respond_to(:xml))
    end
  end

  describe "lifecycle", if: ENV["DFE_RB_LIVE_IE"] do
    it "authorizes, consults, adds a driver, closes and archives an MDF-e" do
      signed = client.sign(manifest(number: number + 1, nfe: nfe_key))
      result = save(client.authorize!(signed))
      expect(result.proc_xml).to include("<mdfeProc", signed.xml)
      expect(DfeRb::Xsd.issues(result.proc_xml, package: "mdfe_3.00", file: "procMDFe_v3.00.xsd")).to eq([])

      expect(client.consult(result.key)).to be_authorized
      expect(client.unclosed.manifests.map(&:key)).to include(result.key)

      driver = save(client.add_driver(result.key, name: "SEGUNDO MOTORISTA", cpf: "52998224725"))
      expect(driver).to be_registered, "#{driver.code} #{driver.message}"

      closed = save(client.close(result.key, protocol: result.protocol, city: city_code))
      expect(closed).to be_registered, "#{closed.code} #{closed.message}"
      expect(DfeRb::Xsd.issues(closed.proc_xml, package: "mdfe_3.00", file: "procEventoMDFe_v3.00.xsd")).to eq([])

      consulted = client.consult(result.key)
      expect(consulted).to be_closed
      expect(consulted.events.map(&:type)).to include("110112", "110114")
    end

    it "authorizes and cancels an MDF-e" do
      result = save(client.authorize!(manifest(number: number + 2, nfe: nfe_key)))

      canceled = save(client.cancel(result.key, protocol: result.protocol, reason: "Teste de cancelamento em homologacao"))

      expect(canceled).to be_registered, "#{canceled.code} #{canceled.message}"
      expect(client.consult(result.key)).to be_canceled
    end
  end
end
