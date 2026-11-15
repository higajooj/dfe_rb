RSpec.describe "An NF-e printed as the DANFE Simplificado Tipo 2 (NT 2026.002, NT 2026.003)" do
  let(:clock) { Struct.new(:now).new(Time.new(2026, 11, 16, 10, 0, 0, "-04:00")) }
  let(:certificate) { nfe_certificate }
  let(:transport) { FakeTransport.new }
  let(:client) { DfeRb::Nfe::Client.new(certificate: certificate, uf: "MS", transport: transport, clock: clock, sleeper: ->(_seconds) {}) }

  # A counter sale to a contractor with a CNPJ and an IE, in MS, for 8.50 paid in cash.
  # `taxes` adds to the item.
  def simplified(builder = client, item: {}, icms: {csosn: "102", origin: :domestic}, taxes: nil, payment: [:money], **options, &block)
    fields = {code: "1", description: "Cimento 50kg", ncm: "25232910", cfop: "5102", unit: "SC", quantity: 1, unit_price: "8.50"}.merge(item)
    builder.build_invoice(**options) do |nfe|
      nfe.print_format :simplified_type_2
      nfe.series 1
      nfe.number 77
      nfe.nature_of_operation "Venda no balcao"
      nfe.issuer(**NfceHelpers::NFCE_ISSUER)
      nfe.recipient cnpj: "11222333000181", name: "CONSTRUTORA", state_registration: "283184527",
        address: {street: "Rua B", number: "1", district: "Centro", city_code: "5002704", zip: "79002000"}
      nfe.item do |i|
        i.__assign(fields)
        i.icms(**icms)
        i.pis cst: "07"
        i.cofins cst: "07"
        taxes&.call(i)
      end
      nfe.payment(*payment) if payment
      block&.call(nfe)
    end
  end

  def issues_of(...) = simplified(...).issues

  describe "building it" do
    it "makes a final consumer's sale, though the buyer has an IE, with the NFC-e's QR code in infNFeSupl" do
      invoice = simplified
      ide = invoice.resolved["ide"]

      expect(ide).to include("mod" => 55, "tpImp" => 6, "indFinal" => 1, "idDest" => 1, "tpNF" => 1, "finNFe" => 1)
      expect(invoice.resolved["dest"]).to include("indIEDest" => 1)
      expect(invoice.resolved["det"].first.dig("prod", "xProd")).to eq("NOTA FISCAL EMITIDA EM AMBIENTE DE HOMOLOGACAO - SEM VALOR FISCAL")
      expect(invoice.issues).to eq([])
      expect(invoice.qr_code).to eq("http://www.dfe.ms.gov.br/nfce/qrcode?p=#{invoice.key}|3|2")
      expect(invoice.consult_url).to eq("www.dfe.ms.gov.br/nfce/consulta")
      expect(invoice.to_xml).to match(%r{</infNFe><infNFeSupl><qrCode>http://www\.dfe\.ms\.gov\.br/nfce/qrcode\?p=\d{44}\|3\|2</qrCode>})
    end

    it "parses back with the gem's own QR code parser" do
      invoice = simplified
      parsed = DfeRb::Nfce::QrCode.parse(invoice.qr_code)

      expect(parsed).to include(address: "http://www.dfe.ms.gov.br/nfce/qrcode", key: invoice.key.to_s, version: "3", environment: "2")
    end

    it "leaves any other NF-e without a QR code" do
      invoice = simples_invoice(nfe_client(transport))

      expect(invoice.qr_code).to be_nil
      expect(invoice.to_xml).not_to include("infNFeSupl")
    end

    it "signs the day, total and buyer of a note issued off-line with the client's certificate (NT 2026.003 §4.3.2)" do
      invoice = simplified { |nfe| nfe.contingency :offline, since: clock.now - 120, reason: "Sem comunicacao com a SEFAZ" }
      parsed = DfeRb::Nfce::QrCode.parse(invoice.qr_code)

      expect(invoice.key.emission_type).to eq(9)
      expect(parsed[:parameters][0, 7]).to eq([invoice.key.to_s, "3", "2", "16", "8.50", "1", "11222333000181"])
      expect(DfeRb::Nfce::QrCode.signed_by?(parsed[:signed_content], parsed[:signature], certificate.certificate)).to be(true)
      expect(invoice.issues).to eq([])
    end

    it "asks for the certificate when built without a client" do
      builder = Object.new.tap { |b| def b.build_invoice(**options, &block) = DfeRb::Nfe::Invoice.new(**options, &block) }
      invoice = simplified(builder) { |nfe| nfe.contingency :offline, since: Time.now - 60, reason: "Sem comunicacao com a SEFAZ" }

      expect(invoice.issues).to include(a_string_matching(/off-line signs its QR code with the certificate; build it with client.build_invoice/))
    end
  end

  describe "the rules NT 2026.002 gives it" do
    it "takes only the CFOPs of RV I08-150, each with its CST or CSOSN (725, 386)" do
      expect(issues_of(item: {cfop: "5949"}))
        .to include(a_string_matching(%r{det\[1\]/prod/CFOP: 5949 can't be used in an NF-e with DANFE Simplificado Tipo 2.*\(rej\. 725\)}))
      expect(issues_of(item: {cfop: "5405"})).to include(a_string_matching(/5405 doesn't go with CSOSN 102.*\(rej\. 386\)/))
    end

    it "takes only the CSTs of RV N12-30 and the CSOSNs of N12a-20 (766, 383)" do
      expect(issues_of(icms: {cst: "10", origin: :domestic}))
        .to include(a_string_matching(%r{ICMS10/CST: an NF-e with DANFE Simplificado Tipo 2 takes CST 00, 20, 40, 41, 60, 61, 90 \(rej\. 766\)}))
      expect(issues_of(icms: {csosn: "101", origin: :domestic, credit_rate: "1.00"}))
        .to include(a_string_matching(%r{ICMSSN101/CSOSN: an NF-e with DANFE Simplificado Tipo 2 takes CSOSN 102, 103, 300, 400, 500, 900 \(rej\. 383\)}))
    end

    it "is an internal sale to a final consumer, in person or delivered (707, 716, 717)" do
      issues = issues_of do |nfe|
        nfe.final_consumer 0
        nfe.presence :internet
      end

      expect(issues).to include("ide/indFinal: an NF-e with DANFE Simplificado Tipo 2 is a sale to a final consumer, indFinal 1 (rej. 716)",
        a_string_matching(/indPres: an NF-e with DANFE Simplificado Tipo 2 is an in-person sale.*\(rej\. 717\)/))
      interstate = issues_of { |nfe| nfe.recipient address: {street: "Rua B", number: "1", district: "Centro", city_code: "3550308", zip: "01001000"} }
      expect(interstate).to include("ide/idDest: an NF-e with DANFE Simplificado Tipo 2 is an internal operation, idDest 1 (rej. 707)")
    end

    it "bars the groups NT 2026.002 bars, a pickup place included (708, 760, 669, 742)" do
      issues = issues_of do |nfe|
        nfe.reference key: "50261111444777000161550010000000011000000014"
        nfe.billing invoice: {number: "1"}
        nfe.pickup cnpj: "11222333000181", street: "Rua C", number: "2", district: "Centro", city_code: "5002704"
      end

      expect(issues).to include("ide/NFref: an NF-e with DANFE Simplificado Tipo 2 can't carry referenced documents (rej. 708)",
        "cobr: an NF-e with DANFE Simplificado Tipo 2 can't carry billing (invoice, installments) (rej. 760)",
        "retirada: an NF-e with DANFE Simplificado Tipo 2 can't carry a pickup place (rej. 669)")
      expect(issues_of(taxes: ->(i) { i.ipi cst: "53" })).to include(a_string_matching(/can't carry IPI \(rej\. 742\)/))
    end

    it "has freight only on a home delivery (753)" do
      expect(issues_of { |nfe| nfe.transport freight_mode: 0 })
        .to include("transp/modFrete: an NF-e with DANFE Simplificado Tipo 2 has freight only on a home delivery, indPres 4; use modFrete 9 (rej. 753)")
    end

    it "keeps the rules of modelo 65 alone off it: payments, the buyer's IE, the carrier" do
      issues = issues_of(payment: [:commercial_installment, "8.50"]) { |nfe| nfe.transport carrier: {name: "TRANSPORTES"} }

      expect(issues).to eq([])
    end

    it "sends it off-line instead of to the SVC, whose key the schema's QR code doesn't take" do
      issues = issues_of { |nfe| nfe.contingency :svc, since: clock.now - 120, reason: "SEFAZ de origem fora do ar" }

      expect(issues).to include(a_string_matching(/Element 'qrCode'/),
        "ide/tpEmis: an NF-e with DANFE Simplificado Tipo 2 can't be issued at the SVC, since the schema's QR code takes no SVC key; " \
        "issue it off-line (contingency :offline)")
    end
  end

  describe "through the client" do
    def authorized_answer = ->(xml) { ret_env_nfe_sync(prot_nfe(xml[/Id="NFe(\d{44})"/, 1])) }

    it "signs it with its QR code ahead of the signature and authorizes it at the NF-e's authorizer" do
      transport.answer(:authorization, authorized_answer)
      signed = client.sign(simplified)
      result = client.authorize(signed)

      expect(signed.xml).to match(%r{</infNFe><infNFeSupl><qrCode>[^<]+\|3\|2</qrCode><urlChave>[^<]+</urlChave></infNFeSupl><Signature})
      expect(DfeRb::Nfe::Signature.verify(signed.xml)).to be(true)
      expect(transport.calls.last.url).to eq("https://hom.nfe.sefaz.ms.gov.br/ws/NFeAutorizacao4")
      expect(result).to be_authorized
      expect(result.qr_code).to eq("http://www.dfe.ms.gov.br/nfce/qrcode?p=#{result.key}|3|2")
      expect(result.proc_xml).to include("<infNFeSupl>")
    end

    it "adds the QR code to one handed in unsigned, and refuses one signed without it (394)" do
      xml = simplified.to_xml.sub(%r{<infNFeSupl>.*</infNFeSupl>}, "")
      signed = client.sign(xml)

      expect(signed.qr_code).to eq("http://www.dfe.ms.gov.br/nfce/qrcode?p=#{signed.key}|3|2")
      bare = DfeRb::Nfe::Signature.sign_nfe(xml, certificate)
      expect { client.sign(bare) }.to raise_error(DfeRb::ValidationError, /a signed NF-e with DANFE Simplificado Tipo 2 carries its QR code \(rej\. 394\)/)
    end

    it "refuses a QR code version other than 3 (ZX02-220, 672)" do
      xml = simplified.to_xml.sub("|3|2<", "|2|2|1|#{"a" * 40}<")

      expect { client.sign(xml) }.to raise_error(DfeRb::ValidationError, /takes QR code version 3, not 2 \(RV ZX02-220, rej\. 672\)/)
    end
  end
end
