RSpec.describe DfeRb::Nfce::Invoice do
  let(:clock) { Struct.new(:now).new(Time.new(2026, 11, 5, 14, 30, 0, "-04:00")) }
  let(:certificate) { nfe_certificate }

  def tree_of(invoice = nfce_invoice(clock: clock)) = invoice.resolved

  describe "defaults" do
    it "makes a final consumer's in-person, internal sale, printed as the DANFE NFC-e" do
      ide = tree_of["ide"]

      expect(ide).to include("mod" => 65, "tpImp" => 4, "tpNF" => 1, "idDest" => 1, "indFinal" => 1, "indPres" => 1,
        "finNFe" => 1, "tpEmis" => 1, "cUF" => "50")
      expect(tree_of["dest"]).to be_nil
      expect(nfce_invoice(clock: clock).issues).to eq([])
    end

    it "describes the first item as RV I04-10 requires in homologação, and only there" do
      expect(tree_of["det"].first.dig("prod", "xProd")).to eq("NOTA FISCAL EMITIDA EM AMBIENTE DE HOMOLOGACAO - SEM VALOR FISCAL")
      production = nfce_invoice(clock: clock, environment: :production)
      expect(production.resolved["det"].first.dig("prod", "xProd")).to eq("Cafe")
    end

    it "takes a consumer as a non-taxpayer, named as homologação requires" do
      dest = tree_of(nfce_invoice(clock: clock) { |nfce| nfce.consumer cpf: "529.982.247-25" })["dest"]

      expect(dest).to include("CPF" => "52998224725", "indIEDest" => 9, "xNome" => "NF-E EMITIDA EM AMBIENTE DE HOMOLOGACAO - SEM VALOR FISCAL")
    end

    it "writes infNFeSupl after infNFe, valid against the schema" do
      xml = nfce_invoice(clock: clock).to_xml

      expect(xml).to match(%r{</infNFe><infNFeSupl><qrCode>http://www\.dfe\.ms\.gov\.br/nfce/qrcode\?p=\d{44}\|3\|2</qrCode>})
      expect(xml).to end_with("<urlChave>www.dfe.ms.gov.br/nfce/consulta</urlChave></infNFeSupl></NFe>")
    end
  end

  describe "QR code" do
    it "holds the key, version 3 and tpAmb for a note issued on-line, with no CSC" do
      invoice = nfce_invoice(clock: clock)

      expect(invoice.qr_code).to eq("http://www.dfe.ms.gov.br/nfce/qrcode?p=#{invoice.key}|3|2")
      expect(invoice.consult_url).to eq("www.dfe.ms.gov.br/nfce/consulta")
    end

    it "takes the addresses the client overrides" do
      invoice = nfce_invoice(clock: clock, endpoints: {qr_code: "https://proxy/qr", consult_url: "https://proxy/consulta"})

      expect(invoice.qr_code).to start_with("https://proxy/qr?p=")
      expect(invoice.consult_url).to eq("https://proxy/consulta")
    end

    it "signs the day, total and recipient of a note issued off-line with the certificate" do
      invoice = nfce_invoice(clock: clock, certificate: certificate) do |nfce|
        nfce.consumer cpf: "529.982.247-25"
        nfce.contingency :offline, since: clock.now - 60, reason: "Sem comunicacao com a SEFAZ"
      end
      parsed = DfeRb::Nfce::QrCode.parse(invoice.qr_code)

      expect(invoice.key.emission_type).to eq(9)
      expect(parsed[:parameters][0, 7]).to eq([invoice.key.to_s, "3", "2", "05", "8.50", "2", "52998224725"])
      expect(DfeRb::Nfce::QrCode.signed_by?(parsed[:signed_content], parsed[:signature], certificate.certificate)).to be(true)
      expect(invoice.issues).to eq([])
    end

    it "asks for the certificate to sign an off-line note's QR code" do
      invoice = nfce_invoice(clock: clock) { |nfce| nfce.contingency :offline, since: clock.now - 60, reason: "Sem comunicacao com a SEFAZ" }

      expect(invoice.qr_code).to be_nil
      expect(invoice.issues).to include(a_string_matching(/off-line signs its QR code with the certificate; build it with client.build_invoice/))
    end
  end

  describe "rules of modelo 65" do
    def issues_of(**options, &block) = nfce_invoice(clock: clock, **options, &block).issues

    it "keeps a note issued off-line out of the NF-e's DANFE Simplificado rule" do
      issues = issues_of(certificate: certificate) { |nfce| nfce.contingency :offline, since: clock.now - 60, reason: "Sem comunicacao com a SEFAZ" }
      expect(issues).to eq([])
    end

    it "bars groups an NFC-e can't carry" do
      issues = issues_of do |nfce|
        nfce.billing invoice: {number: "1"}
        nfce.reference key: "35260911444777000161550010000000011000000015"
      end

      expect(issues).to include("cobr: an NFC-e can't carry billing (invoice, installments) (rej. 760)",
        "ide/NFref: an NFC-e can't carry referenced documents (rej. 708)")
    end

    it "takes only the CFOPs of RV I08-150, and each with its own CST or CSOSN" do
      expect(issues_of(item: {cfop: "5949"}))
        .to include(a_string_matching(/det\[1\]\/prod\/CFOP: 5949 can't be used in an NFC-e.*\(rej. 725\)/))
      expect(issues_of(item: {cfop: "5405"}))
        .to include(a_string_matching(/CFOP: 5405 doesn't go with CSOSN 102, which takes 5101, 5102.*\(rej. 386\)/))
    end

    it "lets a state's own exception through (NT 2023.003)" do
      issuer = NfceHelpers::NFCE_ISSUER.merge(address: {street: "Rua A", number: "1", district: "Centro", city_code: "4314902", zip: "90010000"})
      issues = issues_of(item: {cfop: "5949"}, icms: {csosn: "900", origin: :domestic}) { |nfce| nfce.issuer(**issuer) }

      expect(issues.grep(/CFOP/)).to eq([])
    end

    it "flags a CST or CSOSN an NFC-e can't take" do
      expect(issues_of(icms: {csosn: "101", origin: :domestic, credit_rate: "1.00"}))
        .to include(a_string_matching(/ICMSSN101\/CSOSN: an NFC-e takes CSOSN 102, 103, 300, 400, 500, 900 \(rej. 383\)/))
    end

    it "asks a home delivery for the consumer, the address and the carrier" do
      issues = issues_of { |nfce| nfce.presence :home_delivery }

      expect(issues).to include("dest: a home delivery (indPres 4) identifies the consumer (rej. 787)",
        "transp/transporta: a home delivery (indPres 4) names who carries it (rej. 786)")
      expect(issues_of { |nfce| nfce.presence :internet }).to include(a_string_matching(/indPres: an NFC-e is an in-person sale.*\(rej. 717\)/))
    end

    it "identifies the consumer above R$ 10.000,00" do
      issues = issues_of(item: {unit_price: "10000.01"}, payment: [:money, "10000.01"])

      expect(issues).to include(a_string_matching(/above R\$ 10.000,00 identifies the consumer.*\(rej. 750\)/))
      # The address (W16-60) is each state's call.
      identified = issues_of(item: {unit_price: "10000.01"}, payment: [:money, "10000.01"]) { |nfce| nfce.consumer cpf: "529.982.247-25" }
      expect(identified).to eq([])
    end

    it "bars payments an NFC-e can't take and asks card and PIX payments for the card group" do
      expect(issues_of(payment: [:other, "8.50"])).to include(a_string_matching(/tPag: an NFC-e can't be paid with tPag 99 .*\(rej. 436\)/))
      expect(issues_of(payment: [:pix, "8.50"])).to include(a_string_matching(/detPag\[1\]\/card: a card or PIX payment \(tPag 17\).*\(rej. 391\)/))
      expect(issues_of(payment: nil) { |nfce| nfce.payment kind: :pix, amount: "8.50", card: {integration: :not_integrated} }).to eq([])
    end

    it "takes no SVC and no entry" do
      expect(issues_of { |nfce| nfce.operation_type :entry }).to include(a_string_matching(/tpNF 1 \(rej. 706\)/))
      expect(issues_of { |nfce| nfce.contingency :svc, since: clock.now - 60, reason: "SEFAZ de origem fora do ar" })
        .to include(a_string_matching(/the SVC doesn't authorize NFC-e.*\(rej. 783\)/))
    end

    it "holds a MEI to CSOSN 102 or 300 and CFOP 5102" do
      issues = issues_of(item: {cfop: "5101"}) { |nfce| nfce.issuer(**NfceHelpers::NFCE_ISSUER, tax_regime: :mei) }

      expect(issues).to include(a_string_matching(/a MEI's NFC-e takes CFOP 5102 only/))
    end
  end

  describe "checking a QR code" do
    let(:invoice) { nfce_invoice(clock: clock, certificate: certificate) { |nfce| nfce.contingency :offline, since: clock.now - 60, reason: "Sem comunicacao com a SEFAZ" } }

    def issues_with(qr_code) = DfeRb::Nfce::Validator.new(invoice.resolved, supplement: {"qrCode" => qr_code}, signer: certificate.certificate).issues

    it "accepts the one the gem builds" do
      expect(issues_with(invoice.qr_code)).to eq([])
    end

    it "flags a parameter that differs from the note, and a signature that doesn't verify" do
      tampered = invoice.qr_code.sub("|8.50|", "|9.50|")

      expect(issues_with(tampered)).to include(a_string_matching(/its total 9.50 differs from vNF 8.50 \(rej. 397\)/),
        a_string_matching(/signature doesn't match .* \(rej. 583\)/))
      expect(issues_with(invoice.qr_code.sub(/\|[^|]*\z/, "|")))
        .to include(a_string_matching(/off-line \(tpEmis 9\) carries the day, vNF, recipient and signature \(rej. 474\)/))
    end

    it "checks the day and total of an off-line version 2 QR code, which need no CSC" do
      v2 = "http://www.dfe.ms.gov.br/nfce/qrcode?p=#{invoice.key}|2|2|01|999.00|#{"ab" * 28}|1|#{"c" * 40}"

      expect(issues_with(v2)).to include(a_string_matching(/its day 01 differs from dhEmi's \(rej. 397\)/),
        a_string_matching(/its total 999.00 differs from vNF 8.50 \(rej. 397\)/))
    end

    it "flags another site's address when it knows the state's (rej. 395)" do
      check = ->(url) {
        DfeRb::Nfce::Validator.new(invoice.resolved, supplement: {"qrCode" => url}, signer: certificate.certificate,
          qr_address: "http://www.dfe.ms.gov.br/nfce/qrcode").issues
      }

      expect(check.call(invoice.qr_code.sub("http://www.dfe.ms.gov.br", "https://WWW.DFE.MS.GOV.BR"))).to eq([])
      expect(check.call(invoice.qr_code.sub("www.dfe.ms.gov.br", "example.invalid")))
        .to include(a_string_matching(%r{example.invalid/nfce/qrcode is not the state's QR code consultation.*\(rej. 395\)}))
    end

    it "flags a signature on a note issued on-line" do
      online = nfce_invoice(clock: clock)
      issues = DfeRb::Nfce::Validator.new(online.resolved, supplement: {"qrCode" => "#{online.qr_code}|05|8.50|||abc="}).issues

      expect(issues).to include(a_string_matching(/on-line carries only key, version and tpAmb, no signature \(rej. 445\)/))
    end
  end
end
