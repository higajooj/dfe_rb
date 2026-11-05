# Live checks of the NFC-e against the real SEFAZ homologacao environment. Off by default:
#
#   DFE_RB_LIVE=1 bundle exec rspec spec/live/nfce_homologacao_spec.rb
#
# The certificate and the issuer come from the same variables as spec/live/nfe_homologacao_spec.rb
# (DFE_RB_PFX, DFE_RB_PFX_PASSWORD or DFE_RB_PFX_PASSWORD_FILE; DFE_RB_LIVE_UF, _IE, _NAME,
# _CITY_CODE, _ZIP, _STREET, _STREET_NUMBER, _DISTRICT, _REGIME and _ICMS_RATE). Nothing here
# touches production.
#
# The "protocol" examples need only a valid certificate. The "lifecycle" ones need an issuer
# accredited for the NFC-e at its state (otherwise 781), and are skipped without DFE_RB_LIVE_IE.
# Their notes are numbered from the clock and canceled, by substitution or not, once
# authorized.
RSpec.describe "NFC-e against SEFAZ homologacao", live: true do
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
  let(:uf) { ENV.fetch("DFE_RB_LIVE_UF", "MS") }
  let(:client) { DfeRb::Nfce::Client.new(certificate: certificate, uf: uf, environment: :homologacao, timeouts: {read: 60}) }

  describe "protocol" do
    it "finds every NFC-e authorizer in service" do
      # One state per authorizer; BA stands for the SVRS.
      %w[AM GO MG MS MT PR RS SP BA].each do |state|
        status = DfeRb::Nfce::Client.new(certificate: certificate, uf: state, environment: :homologacao).status
        expect(status).to be_online, "#{state}: #{status.code} #{status.message}"
      end
    end

    it "understands a consult, answering that the key is unknown" do
      key = DfeRb::Nfce::AccessKey.build(state: uf, issued_at: Time.now, tax_id: certificate.cnpj, series: 1, number: 999_999, numeric_code: "87654321")

      expect(client.consult(key.to_s).status).to eq(:not_found)
    end
  end

  describe "lifecycle", if: ENV["DFE_RB_LIVE_IE"] do
    let(:issuer) do
      {tax_id: certificate.cnpj, name: ENV.fetch("DFE_RB_LIVE_NAME", "EMPRESA DE TESTE LTDA"), state_registration: ENV.fetch("DFE_RB_LIVE_IE"),
       tax_regime: ENV.fetch("DFE_RB_LIVE_REGIME", "simples").to_sym,
       address: {street: ENV.fetch("DFE_RB_LIVE_STREET", "Rua Teste"), number: ENV.fetch("DFE_RB_LIVE_STREET_NUMBER", "100"),
                 district: ENV.fetch("DFE_RB_LIVE_DISTRICT", "Centro"), city_code: ENV.fetch("DFE_RB_LIVE_CITY_CODE"), zip: ENV.fetch("DFE_RB_LIVE_ZIP")}}
    end
    # Fixed once per run, apart from earlier runs by the clock; each example takes its own
    # numbers above it.
    def self.base_number = @base_number ||= Integer(ENV.fetch("DFE_RB_LIVE_NUMBER", Time.now.to_i.to_s[-7..]), 10)

    let(:base_number) { self.class.base_number }

    def sale(number, offline: false, consumer: nil)
      client.build_invoice do |nfce|
        nfce.series 1
        nfce.number number
        nfce.nature_of_operation "Venda ao consumidor"
        nfce.issuer(**issuer)
        nfce.consumer(**consumer) if consumer
        nfce.item do |i|
          i.code "1"
          i.description "Cafe torrado 500g"
          i.ncm "09012100"
          i.cfop "5102"
          i.unit "UN"
          i.quantity 2
          i.unit_price "8.50"
          if issuer[:tax_regime] == :normal
            i.icms cst: "00", origin: :domestic, rate: ENV.fetch("DFE_RB_LIVE_ICMS_RATE", "17.00")
            i.ibs_cbs class_code: "000001"
          else
            i.icms csosn: "102", origin: :domestic
          end
          i.pis cst: "07"
          i.cofins cst: "07"
        end
        nfce.payment kind: :pix, card: {integration: :not_integrated}
        # Several authorizers (MS among them) reject notes without a responsavel tecnico (972).
        nfce.technical_contact cnpj: certificate.cnpj, contact: "Responsavel Tecnico", email: "teste@example.com", phone: "6733333333"
        nfce.contingency :offline, since: Time.now - 120, reason: "Teste de contingencia off-line em homologacao" if offline
      end
    end

    def authorized(input)
      result = client.authorize(input)
      expect(result).to be_authorized, "#{result.code} #{result.message}"
      result
    end

    it "authorizes, consults, cancels and archives an NFC-e, and inutilizes a number" do
      signed = client.sign(sale(base_number))
      result = authorized(signed)
      expect(result.proc_xml).to include(signed.xml, "<qrCode>")
      expect(client.consult(signed.key).protocol).to eq(result.protocol)

      cancellation = client.cancel(signed.key, protocol: result.protocol, reason: "Cancelamento de teste do ambiente de homologacao")
      expect(cancellation).to be_registered, "#{cancellation.code} #{cancellation.message}"
      expect(client.consult(signed.key)).to be_canceled

      unused = client.inutilize(series: 1, from: base_number + 10, reason: "Inutilizacao de teste do ambiente de homologacao")
      expect(unused).to be_approved, "#{unused.code} #{unused.message}"
    end

    # The off-line note's QR code carries its parameters signed with the certificate, which
    # SEFAZ checks (rej. 583); the substitution compares both notes (rej. 914-919).
    it "authorizes a note issued off-line and cancels by substitution the one it replaced" do
      consumer = {cpf: "52998224725"}
      original = client.sign(sale(base_number + 1, consumer: consumer))
      replacement = client.sign(sale(base_number + 2, offline: true, consumer: consumer))
      expect(DfeRb::Nfce::AccessKey.parse(replacement.key).emission_type).to eq(9)

      first = authorized(original)
      second = authorized(replacement)

      substitution = client.cancel_by_substitution(original.key, protocol: first.protocol, replacement: replacement.key,
        reason: "Emitida em contingencia off-line para a mesma venda")
      expect(substitution).to be_registered, "#{substitution.code} #{substitution.message}"
      expect(substitution.proc_xml).to include("<tpEvento>110112</tpEvento>")
      expect(client.consult(original.key)).to be_canceled

      cancellation = client.cancel(replacement.key, protocol: second.protocol, reason: "Cancelamento de teste do ambiente de homologacao")
      expect(cancellation).to be_registered, "#{cancellation.code} #{cancellation.message}"
    end

    it "gives an NFC-e handed in as XML its QR code before signing it" do
      xml = sale(base_number + 3).to_xml.sub(%r{<infNFeSupl>.*</infNFeSupl>}, "")
      signed = client.sign(xml)
      result = authorized(signed)

      cancellation = client.cancel(signed.key, protocol: result.protocol, reason: "Cancelamento de teste do ambiente de homologacao")
      expect(cancellation).to be_registered, "#{cancellation.code} #{cancellation.message}"
    end
  end
end
