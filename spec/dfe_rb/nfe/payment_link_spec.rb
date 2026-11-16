# NT 2026.006 v1.01: the link of a payment transaction to the note (group YC, gPgtoVinc) and event
# 110300, with IT 2026.001's table of means of payment and the event 110001 that takes it back.
RSpec.describe "NT 2026.006 v1.01" do
  let(:transport) { NfeHelpers::FakeTransport.new }
  let(:client) { nfe_client(transport) }
  let(:ns) { {"nfe" => NfeHelpers::NFE_NS} }
  let(:key) { client.sign(simples_invoice(client)).key }

  def doc(invoice) = Nokogiri::XML(invoice.to_xml)

  def text(document, path) = document.at_xpath(path, ns)&.text

  def linked_invoice(at: "2026-12-14T10:00:00-03:00")
    simples_invoice(client) do |nfe|
      nfe.issued_at at
      nfe.payment_link :bank_slip, transaction_id: "BOLETO-0001", receiver_cnpj: "11.222.333/0001-81", psp_cnpj_base: "00000000"
      nfe.payment_link :pix, transaction_id: "E00038166202612141000abcdef12345", receiver_cnpj: "11222333000181", psp_cnpj_base: "00038166"
    end
  end

  describe "IT 2026.001" do
    it "lists the means of payment a transaction may link, with the new codes 23 and 24" do
      expect(DfeRb::Nfe::Tables.payment_link_methods.map(&:code)).to eq(%w[15 17 18 20 23 24])
      expect(DfeRb::Nfe::Tables.payment_link_method(17).title).to eq("Pix QRCode")
      expect(DfeRb::Nfe::Tables.payment_link_method("01")).to be_nil
    end
  end

  describe "the group gPgtoVinc on a note (YC)" do
    it "writes each transaction, numbered from 1, ahead of the additional information" do
      invoice = linked_invoice
      document = doc(invoice)

      expect(invoice.issues).to eq([])
      expect(document.xpath("//nfe:gPgtoVinc/nfe:gPgto/@nPag", ns).map(&:value)).to eq(%w[1 2])
      expect(document.xpath("//nfe:gPgtoVinc/nfe:gPgto/@idTransacao", ns).map(&:value)).to eq(%w[BOLETO-0001 E00038166202612141000abcdef12345])
      expect(document.xpath("//nfe:gPgtoVinc/nfe:gPgto/nfe:tpMeioPgto", ns).map(&:text)).to eq(%w[15 17])
      expect(text(document, "//nfe:gPgtoVinc/nfe:gPgto[1]/nfe:CNPJReceb")).to eq("11222333000181")
      expect(text(document, "//nfe:gPgtoVinc/nfe:gPgto[2]/nfe:CNPJBasePSP")).to eq("00038166")
      expect(document.at_xpath("//nfe:pag/following-sibling::*[1]", ns).name).to eq("gPgtoVinc")
      expect(DfeRb::Nfe::Schemas.nfe_issues(invoice.to_xml)).to eq([])
    end

    it "leaves the group out of a note that links nothing" do
      expect(doc(simples_invoice(client)).at_xpath("//nfe:gPgtoVinc", ns)).to be_nil
    end

    def issues_of(links, at: "2026-12-14T10:00:00-03:00", env: "1")
      tree = {"ide" => {"finNFe" => "1", "tpAmb" => env, "dhEmi" => at}, "det" => [], "gPgtoVinc" => {"gPgto" => links}}
      DfeRb::Nfe::Validator.new(tree).issues.grep(/gPgtoVinc/)
    end

    let(:link) { {"@nPag" => 1, "@idTransacao" => "ID-1", "tpMeioPgto" => "17", "CNPJReceb" => "11222333000181", "CNPJBasePSP" => "00038166"} }

    it "refuses a means of payment outside IT 2026.001 (YC05-10, rej. 1273)" do
      expect(issues_of([link.merge("tpMeioPgto" => "01")]))
        .to eq(["gPgtoVinc/gPgto[1]/tpMeioPgto: 01 is not a means of payment of IT 2026.001 (RV YC05-10, rej. 1273)"])
      expect(issues_of([link.merge("tpMeioPgto" => "24")])).to eq([])
    end

    it "refuses a receiver whose CNPJ isn't valid (YC06-10, rej. 1274)" do
      expect(issues_of([link.merge("CNPJReceb" => "11222333000182")]))
        .to eq(["gPgtoVinc/gPgto[1]/CNPJReceb: 11222333000182 is not a valid CNPJ (RV YC06-10, rej. 1274)"])
      expect(issues_of([link.merge("CNPJReceb" => "12ABC34501DE35")])).to eq([])
    end

    it "refuses a repeated nPag or idTransacao, which the schema forbids (YC03-10, YC04-20, rej. 215)" do
      expect(issues_of([link, link.merge("@idTransacao" => "ID-2")]))
        .to eq(["gPgtoVinc/gPgto: nPag 1 is repeated (RV YC03-10, rej. 215: the schema forbids it)"])
      expect(issues_of([link, link.merge("@nPag" => 2)]))
        .to eq(["gPgtoVinc/gPgto: idTransacao ID-1 is repeated (RV YC04-20, rej. 215: the schema forbids it)"])
      invoice = simples_invoice(client) do |nfe|
        nfe.issued_at "2026-12-14T10:00:00-03:00"
        nfe.payment_link :pix, transaction_id: "ID-1", receiver_cnpj: "11222333000181", psp_cnpj_base: "00038166"
        nfe.payment_link :pix, transaction_id: "ID-1", receiver_cnpj: "11222333000181", psp_cnpj_base: "00038166"
      end
      expect { invoice.to_xml }.to raise_error(DfeRb::ValidationError, /idTransacao ID-1 is repeated \(RV YC04-20, rej. 215/)
    end

    it "applies from 14/12/2026 in production and 26/10/2026 in homologação, by dhEmi" do
      bad = [link.merge("tpMeioPgto" => "01")]

      expect(issues_of(bad, at: "2026-12-13T23:59:00-03:00")).to eq([])
      expect(issues_of(bad, at: "2026-12-14T00:00:00-03:00").size).to eq(1)
      expect(issues_of(bad, at: "2026-10-25T23:59:00-03:00", env: "2")).to eq([])
      expect(issues_of(bad, at: "2026-10-26T00:00:00-03:00", env: "2").size).to eq(1)
    end
  end

  describe "event 110300, Vinculação Pagamento" do
    let(:protocol) { "135260000000123" }
    let(:details) { {transaction_id: "E00038166202612141000abcdef12345", method: :pix, receiver_cnpj: "11.222.333/0001-81", psp_cnpj_base: "00038166"} }

    def request_xml = Nokogiri::XML(transport.calls_to(:event).first.xml)

    it "registers the link with the issuer as its author, signed and against its schema" do
      transport.answer(:event, ret_env_evento(key, type: "110300"))

      result = client.link_payment(key, protocol: protocol, **details)

      expect(result).to be_registered
      expect(result.type).to eq("110300")
      info = request_xml.at_xpath("//nfe:infEvento", ns)
      expect(info["Id"]).to eq("ID110300#{key}01")
      expect(info.at_xpath("nfe:cOrgao", ns).text).to eq("35")
      expect(info.at_xpath("nfe:tpEvento", ns).text).to eq("110300")
      detail = info.at_xpath("nfe:detEvento", ns)
      expect(detail.at_xpath("nfe:descEvento", ns).text).to eq("Vinculacao Pagamento")
      expect(detail.at_xpath("nfe:tpAutor", ns).text).to eq("1")
      expect(detail.at_xpath("nfe:nProt", ns).text).to eq(protocol)
      expect(detail.at_xpath("nfe:gPgto/@idTransacao", ns).value).to eq("E00038166202612141000abcdef12345")
      expect(detail.at_xpath("nfe:gPgto/nfe:tpMeioPgto", ns).text).to eq("17")
      expect(detail.at_xpath("nfe:gPgto/nfe:CNPJReceb", ns).text).to eq("11222333000181")
      expect(detail.at_xpath("nfe:gPgto/nfe:CNPJBasePSP", ns).text).to eq("00038166")
      expect(DfeRb::Nfe::Events.detail_issues("110300", DfeRb::Nfe::Distribution::Xml.fragment(detail))).to eq([])
      expect(DfeRb::Nfe::Signature.verify(transport.calls_to(:event).first.xml)).to be(true)
      expect(result.filename).to eq("#{key}_110300_01-procEventoNFe.xml")
    end

    it "takes a means of payment as a code too, and numbers a second link" do
      transport.answer(:event, ret_env_evento(key, type: "110300", sequence: 2))

      client.link_payment(key, protocol: protocol, **details, method: "15", sequence: 2)

      expect(request_xml.at_xpath("//nfe:infEvento/@Id", ns).value).to eq("ID110300#{key}02")
      expect(request_xml.at_xpath("//nfe:tpMeioPgto", ns).text).to eq("15")
    end

    it "refuses a means of payment or a receiver the rules refuse, before sending (P26-10, P27-10)" do
      expect { client.link_payment(key, protocol: protocol, **details, method: "01") }
        .to raise_error(DfeRb::ValidationError, /tpMeioPgto: 01 is not a means of payment of IT 2026.001 \(RV P26-10, rej. 1273\)/)
      expect { client.link_payment(key, protocol: protocol, **details, receiver_cnpj: "11222333000182") }
        .to raise_error(DfeRb::ValidationError, /CNPJReceb: 11222333000182 is not a valid CNPJ \(RV P27-10, rej. 1274\)/)
      expect { client.link_payment(key, protocol: protocol, **details, method: :cheque) }.to raise_error(ArgumentError, /unknown value :cheque for tpMeioPgto/)
      expect { client.link_payment(key, protocol: "123", **details) }.to raise_error(ArgumentError, /protocol/)
      expect { client.link_payment(key, protocol: protocol, **details, sequence: 100) }.to raise_error(ArgumentError, /sequence/)
      expect(transport.calls).to be_empty
    end

    it "checks the identifier and the PSP against the event's schema" do
      expect { client.link_payment(key, protocol: protocol, **details, transaction_id: "X") }.to raise_error(DfeRb::ValidationError, /idTransacao/)
      expect { client.link_payment(key, protocol: protocol, **details, psp_cnpj_base: "123") }.to raise_error(DfeRb::ValidationError, /CNPJBasePSP/)
    end

    it "is taken back by event 110001, which carries the sequence of the event it cancels" do
      transport.answer(:event, ret_env_evento(key, type: "110001", sequence: 2))

      result = client.cancel_event(key, type: "110300", protocol: "135260000000999", sequence: 2)

      expect(result).to be_registered
      info = request_xml.at_xpath("//nfe:infEvento", ns)
      expect(info["Id"]).to eq("ID110001#{key}02")
      expect(info.at_xpath("nfe:detEvento/nfe:descEvento", ns).text).to eq("Cancelamento de Evento")
      expect(info.at_xpath("nfe:detEvento/nfe:tpEventoAut", ns).text).to eq("110300")
      expect(info.at_xpath("nfe:detEvento/nfe:nProtEvento", ns).text).to eq("135260000000999")
      expect(DfeRb::Nfe::Events.detail_issues("110001", DfeRb::Nfe::Distribution::Xml.fragment(info.at_xpath("nfe:detEvento", ns)))).to eq([])
    end

    it "can't cancel an event that can't be cancelled, such as another cancellation" do
      expect { client.cancel_event(key, type: "110001", protocol: "135260000000999") }.to raise_error(DfeRb::ValidationError, /tpEventoAut/)
    end
  end
end
