# Live checks against the real SEFAZ homologacao environment. Off by default:
#
#   DFE_RB_LIVE=1 bundle exec rspec spec/live
#
# The certificate comes from DFE_RB_PFX / DFE_RB_PFX_PASSWORD (or _FILE), falling back to the
# git-ignored notes/cert/cert.pfx + password.txt. Nothing here touches production.
#
# The "protocol" examples only need a valid certificate: they check that SEFAZ understands what
# the gem sends (SOAP contract, signatures, schema) by looking at the answers. The "lifecycle"
# example needs an issuer registered at the state (DFE_RB_LIVE_UF, DFE_RB_LIVE_IE and an address
# through DFE_RB_LIVE_CITY_CODE / _CITY / _ZIP / _STREET / _DISTRICT); it is skipped otherwise.
RSpec.describe "NF-e against SEFAZ homologacao", live: true do
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
  let(:uf) { ENV.fetch("DFE_RB_LIVE_UF", "SP") }
  let(:client) { DfeRb::Nfe::Client.new(certificate: certificate, uf: uf, timeouts: {read: 60}) }

  describe "protocol" do
    it "finds every authorizer in service" do
      %w[SP MG PR RS BA GO MS MT PE AM MA RJ].each do |state|
        status = DfeRb::Nfe::Client.new(certificate: certificate, uf: state).status
        expect(status).to be_online, "#{state}: #{status.code} #{status.message}"
      end
    end

    it "understands a consult, answering that the key is unknown" do
      key = DfeRb::Nfe::AccessKey.build(state: uf, issued_at: Time.now, tax_id: certificate.cnpj, series: 1, number: 999_999, numeric_code: "87654321")
      result = client.consult(key.to_s)

      expect(result.status).to eq(:not_found)
    end

    it "accepts a signed, schema-valid NFe and answers with a business verdict" do
      invoice = client.build_invoice do |nfe|
        nfe.series 1
        nfe.number 1
        nfe.nature_of_operation "Venda de mercadoria"
        nfe.issuer tax_id: certificate.cnpj, name: "EMPRESA DE TESTE LTDA", state_registration: "111111111111", tax_regime: :simples,
          address: {street: "Rua Teste", number: "100", district: "Centro", city_code: "3550308", city: "Sao Paulo", state: "SP", zip: "01001000"}
        nfe.recipient cnpj: certificate.cnpj, name: "CLIENTE",
          address: {street: "Rua Teste", number: "100", district: "Centro", city_code: "3550308", city: "Sao Paulo", state: "SP", zip: "01001000"}
        nfe.item do |i|
          i.code "1"
          i.description "Produto"
          i.ncm "84713012"
          i.cfop "5102"
          i.unit "UN"
          i.quantity 1
          i.unit_price "10.00"
          i.icms csosn: "102", origin: :domestic
          i.pis cst: "07"
          i.cofins cst: "07"
        end
        nfe.payment :money, "10.00"
      end

      result = client.authorize(invoice)

      # Not a signature/schema/parsing problem: those have their own codes (2xx, 4xx).
      expect([100, 209, 245, 203, 205, 206, 207, 208, 210, 230, 231, 233]).to include(result.code), "#{result.code} #{result.message}"
    end

    it "understands events and inutilizacao, answering about the missing note or issuer" do
      key = DfeRb::Nfe::AccessKey.build(state: "SP", issued_at: Time.now, tax_id: certificate.cnpj, series: 1, number: 999_998, numeric_code: "11223344")

      cancel = DfeRb::Nfe::Client.new(certificate: certificate, uf: "SP").cancel(key, protocol: "135260000000001", reason: "Teste de cancelamento em homologacao")
      expect(cancel.code).to eq(494)

      inutilize = DfeRb::Nfe::Client.new(certificate: certificate, uf: "SP").inutilize(series: 1, from: 999_001, reason: "Teste de inutilizacao em homologacao")
      expect([102, 203, 241, 256]).to include(inutilize.code), "#{inutilize.code} #{inutilize.message}"
    end
  end

  describe "lifecycle", if: ENV["DFE_RB_LIVE_IE"] do
    it "authorizes, consults, corrects, cancels and archives an NF-e" do
      issuer = {
        tax_id: certificate.cnpj, name: ENV.fetch("DFE_RB_LIVE_NAME", "EMPRESA DE TESTE LTDA"), state_registration: ENV.fetch("DFE_RB_LIVE_IE"),
        tax_regime: ENV.fetch("DFE_RB_LIVE_REGIME", "simples").to_sym,
        address: {street: ENV.fetch("DFE_RB_LIVE_STREET", "Rua Teste"), number: "100", district: ENV.fetch("DFE_RB_LIVE_DISTRICT", "Centro"),
                  city_code: ENV.fetch("DFE_RB_LIVE_CITY_CODE"), city: ENV.fetch("DFE_RB_LIVE_CITY"), state: uf, zip: ENV.fetch("DFE_RB_LIVE_ZIP")}
      }
      number = Integer(ENV.fetch("DFE_RB_LIVE_NUMBER", Time.now.to_i.to_s[-7..]))

      invoice = client.build_invoice do |nfe|
        nfe.series 1
        nfe.number number
        nfe.nature_of_operation "Venda de mercadoria"
        nfe.issuer(**issuer)
        nfe.recipient cnpj: certificate.cnpj, name: "CLIENTE", address: issuer[:address]
        nfe.item do |i|
          i.code "1"
          i.description "Produto"
          i.ncm "84713012"
          i.cfop "5102"
          i.unit "UN"
          i.quantity 1
          i.unit_price "10.00"
          i.icms csosn: "102", origin: :domestic
          i.pis cst: "07"
          i.cofins cst: "07"
        end
        nfe.payment :money, "10.00"
      end

      signed = client.sign(invoice)
      result = client.authorize!(signed)
      expect(result.proc_xml).to include(signed.xml)

      consulted = client.consult(signed.key)
      expect(consulted).to be_authorized
      expect(consulted.protocol).to eq(result.protocol)

      correction = client.correct(signed.key, text: "Correcao de teste do ambiente de homologacao", sequence: 1)
      expect(correction).to be_registered, "#{correction.code} #{correction.message}"

      cancellation = client.cancel(signed.key, protocol: result.protocol, reason: "Cancelamento de teste do ambiente de homologacao")
      expect(cancellation).to be_registered, "#{cancellation.code} #{cancellation.message}"
      expect(client.consult(signed.key)).to be_canceled

      unused = client.inutilize(series: 1, from: number + 10, reason: "Inutilizacao de teste do ambiente de homologacao")
      expect(unused).to be_approved, "#{unused.code} #{unused.message}"
    end
  end
end
