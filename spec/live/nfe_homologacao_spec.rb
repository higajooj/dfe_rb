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
# through DFE_RB_LIVE_CITY_CODE / _CITY / _ZIP / _STREET / _STREET_NUMBER / _DISTRICT); it is skipped otherwise.
# DFE_RB_LIVE_REGIME=normal switches the item to ICMS 00 plus IBS/CBS (required in homologacao).
# DFE_RB_LIVE_ICMS_RATE is the internal ICMS rate of the issuer's state (default 17.00, MS).
#
# These checks show that SEFAZ accepts what the gem sends and derives. They don't show that
# the tax inputs are right for a product in a given state: that is state law, and SEFAZ
# authorizes a wrong internal rate all the same.
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
  let(:icms_rate) { ENV.fetch("DFE_RB_LIVE_ICMS_RATE", "17.00") }
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
      # The issuer below is in SP, so this goes to SP whatever DFE_RB_LIVE_UF says.
      sp = DfeRb::Nfe::Client.new(certificate: certificate, uf: "SP", timeouts: {read: 60})
      invoice = sp.build_invoice do |nfe|
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

      result = sp.authorize(invoice)

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
        address: {street: ENV.fetch("DFE_RB_LIVE_STREET", "Rua Teste"), number: ENV.fetch("DFE_RB_LIVE_STREET_NUMBER", "100"), district: ENV.fetch("DFE_RB_LIVE_DISTRICT", "Centro"),
                  city_code: ENV.fetch("DFE_RB_LIVE_CITY_CODE"), city: ENV.fetch("DFE_RB_LIVE_CITY"), state: uf, zip: ENV.fetch("DFE_RB_LIVE_ZIP")}
      }
      number = Integer(ENV.fetch("DFE_RB_LIVE_NUMBER", Time.now.to_i.to_s[-7..]), 10)

      invoice = client.build_invoice do |nfe|
        nfe.series 1
        nfe.number number
        nfe.nature_of_operation "Venda de mercadoria"
        nfe.issuer(**issuer)
        nfe.recipient cnpj: certificate.cnpj, name: "CLIENTE", state_registration: issuer[:state_registration], address: issuer[:address]
        nfe.item do |i|
          i.code "1"
          i.description "Produto"
          i.ncm "84713012"
          i.cfop "5102"
          i.unit "UN"
          i.quantity 1
          i.unit_price "10.00"
          if issuer[:tax_regime] == :normal
            i.icms cst: "00", origin: :domestic, base_mode: 3, base: "10.00", rate: icms_rate, amount: DfeRb::Nfe::Totals.money(BigDecimal(icms_rate) / 10).to_s("F")
            i.ibs_cbs cst: "000", class_code: "000001", base: "10.00", ibs_uf: {rate: "0.10", amount: "0.01"},
              ibs_municipal: {rate: "0", amount: "0"}, cbs: {rate: "0.90", amount: "0.09"}
          else
            i.icms csosn: "102", origin: :domestic
          end
          i.pis cst: "07"
          i.cofins cst: "07"
        end
        nfe.payment :money, "10.00"
        # Several authorizers (MS among them) reject notes without a responsavel tecnico (972).
        nfe.technical_contact cnpj: certificate.cnpj, contact: "Responsavel Tecnico", email: "teste@example.com", phone: "1133333333"
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

    # Regime normal notes that give only bases, rates and the tax classification: every amount,
    # rate, total, CFOP prefix and city code comes from the gem, and SEFAZ must agree with it.
    describe "derived values" do
      let(:issuer) do
        {tax_id: certificate.cnpj, name: ENV.fetch("DFE_RB_LIVE_NAME", "EMPRESA DE TESTE LTDA"), state_registration: ENV.fetch("DFE_RB_LIVE_IE"),
         tax_regime: :normal,
         address: {street: ENV.fetch("DFE_RB_LIVE_STREET", "Rua Teste"), number: ENV.fetch("DFE_RB_LIVE_STREET_NUMBER", "100"),
                   district: ENV.fetch("DFE_RB_LIVE_DISTRICT", "Centro"), city_code: ENV.fetch("DFE_RB_LIVE_CITY_CODE"), zip: ENV.fetch("DFE_RB_LIVE_ZIP")}}
      end

      def item(nfe, code, price, rate: nil, class_code: "000001", ncm: "84713012")
        nfe.item do |i|
          i.code code
          i.description "Produto #{code}"
          i.ncm ncm
          i.cfop "102"
          i.unit "UN"
          i.quantity 2
          i.unit_price price
          i.icms(**{cst: "00", origin: :domestic, base_mode: 3, base: DfeRb::Nfe::Totals.money(BigDecimal(price) * 2).to_s("F"), rate: rate}.compact)
          i.pis cst: "01", base: DfeRb::Nfe::Totals.money(BigDecimal(price) * 2).to_s("F"), rate: "1.65"
          i.cofins cst: "01", base: DfeRb::Nfe::Totals.money(BigDecimal(price) * 2).to_s("F"), rate: "7.60"
          i.ibs_cbs class_code: class_code
          yield i if block_given?
        end
      end

      def authorize_and_cancel(invoice)
        signed = client.sign(invoice)
        result = client.authorize(signed)
        expect(result).to be_authorized, "#{result.code} #{result.message}\n#{signed.xml}"

        cancellation = client.cancel(signed.key, protocol: result.protocol, reason: "Cancelamento de teste do ambiente de homologacao")
        expect(cancellation).to be_registered, "#{cancellation.code} #{cancellation.message}"
        Nokogiri::XML(signed.xml)
      end

      it "authorizes an internal sale whose taxes, totals and codes were all derived" do
        invoice = client.build_invoice do |nfe|
          nfe.series 2   # apart from the lifecycle example's series 1, whose numbers also come from the clock
          nfe.number Integer(Time.now.to_i.to_s[-7..], 10)
          nfe.nature_of_operation "Venda de mercadoria"
          nfe.issuer(**issuer)
          nfe.recipient cnpj: certificate.cnpj, name: "CLIENTE", state_registration: issuer[:state_registration],
            address: issuer[:address].except(:city_code).merge(city: ENV.fetch("DFE_RB_LIVE_CITY"), state: uf)
          item(nfe, "1", "123.45", rate: icms_rate)
          # 200034 (60% off, LC 214 art. 210) covers only Annex VII foods: mel natural is one.
          item(nfe, "2", "37.33", rate: icms_rate, class_code: "200034", ncm: "04090000") { |i| i.discount "1.11" }
          nfe.billing invoice: {number: "1"}, installments: [{due_date: (Date.today + 30).iso8601}]
          nfe.payment :bank_slip
          nfe.technical_contact cnpj: certificate.cnpj, contact: "Responsavel Tecnico", email: "teste@example.com", phone: "1133333333"
        end

        document = authorize_and_cancel(invoice)
        ns = {"n" => "http://www.portalfiscal.inf.br/nfe"}
        expect(document.xpath("//n:prod/n:CFOP", ns).map(&:text).uniq).to eq(["5102"])
        expect(document.at_xpath("//n:det[2]//n:gCBS/n:gRed/n:pRedAliq", ns).text).to eq("60.00")
        expect(document.at_xpath("//n:total/n:vNFTot", ns).text).to eq(document.at_xpath("//n:ICMSTot/n:vNF", ns).text)
      end

      it "authorizes an interstate sale to a final consumer with the DIFAL derived" do
        invoice = client.build_invoice do |nfe|
          nfe.series 3
          nfe.number Integer(Time.now.to_i.to_s[-7..], 10)
          nfe.nature_of_operation "Venda de mercadoria"
          nfe.issuer(**issuer)
          nfe.recipient cpf: "52998224725", name: "CONSUMIDOR",
            address: {street: "Rua B", number: "1", district: "Centro", city: "São Paulo", state: "SP", zip: "01001000"}
          item(nfe, "1", "250.00") do |i|
            i.icms_destination destination_base: "500.00", destination_rate: "18.00", destination_fcp_base: "500.00",
              destination_fcp_rate: "2.00"
          end
          nfe.payment :pix
          nfe.technical_contact cnpj: certificate.cnpj, contact: "Responsavel Tecnico", email: "teste@example.com", phone: "1133333333"
        end

        document = authorize_and_cancel(invoice)
        ns = {"n" => "http://www.portalfiscal.inf.br/nfe"}
        expect(document.at_xpath("//n:ICMS00/n:pICMS", ns).text).to eq("12.00")
        expect(document.at_xpath("//n:ICMSUFDest/n:vICMSUFDest", ns).text).to eq("30.00")
      end
    end
  end
end
