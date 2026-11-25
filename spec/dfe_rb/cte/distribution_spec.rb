require "base64"
require "stringio"
require "zlib"

RSpec.describe DfeRb::Cte::Distribution::Client do
  let(:transport) { FakeTransport.new }
  let(:client) { described_class.new(certificate: cte_certificate, uf: "SP", transport: transport) }

  def gzip_b64(xml)
    buf = StringIO.new("".b)
    gz = Zlib::GzipWriter.new(buf)
    gz.write(xml)
    gz.close
    Base64.strict_encode64(buf.string)
  end

  def ret_dist(code: 138, message: "Documento localizado", last_nsu: "000000000000001", max_nsu: "000000000000002", docs: [])
    lote = if docs.any?
      items = docs.map do |nsu, schema, xml|
        nsu_attr = nsu ? %( NSU="#{nsu}") : ""
        %(<docZip#{nsu_attr} schema="#{schema}">#{gzip_b64(xml)}</docZip>)
      end.join
      "<loteDistDFeInt>#{items}</loteDistDFeInt>"
    end
    cursors = +""
    cursors << "<ultNSU>#{last_nsu}</ultNSU>" if last_nsu
    cursors << "<maxNSU>#{max_nsu}</maxNSU>" if max_nsu
    %(<retDistDFeInt xmlns="#{cte_ns}" versao="1.00"><tpAmb>2</tpAmb><verAplic>1.0.0</verAplic><cStat>#{code}</cStat>) +
      %(<xMotivo>#{message}</xMotivo><dhResp>2026-11-24T12:00:00</dhResp>#{cursors}#{lote}</retDistDFeInt>)
  end

  it "distributes cteProc and procEventoCTe documents with typed metadata" do
    signed = cte_client.sign(road_waybill(cte_client))
    proc_xml = DfeRb::Cte::Proc.cte(signed.xml, prot_cte(signed.key, digest: signed.digest_value))
    ev_xml = %(<procEventoCTe xmlns="#{cte_ns}" versao="4.00"><eventoCTe versao="4.00"><infEvento Id="ID110111#{signed.key}001"><cOrgao>35</cOrgao><tpAmb>2</tpAmb><CNPJ>#{cte_issuer}</CNPJ><chCTe>#{signed.key}</chCTe><dhEvento>2026-11-24T10:05:00-03:00</dhEvento><tpEvento>110111</tpEvento><nSeqEvento>1</nSeqEvento><detEvento versaoEvento="4.00"><evCancCTe><descEvento>Cancelamento</descEvento><nProt>135260000000123</nProt><xJust>Erro de digitacao no frete</xJust></evCancCTe></detEvento></infEvento></eventoCTe><retEventoCTe versao="4.00"><infEvento><tpAmb>2</tpAmb><verAplic>SP</verAplic><cOrgao>35</cOrgao><cStat>135</cStat><xMotivo>Evento registrado</xMotivo><chCTe>#{signed.key}</chCTe><tpEvento>110111</tpEvento><nSeqEvento>1</nSeqEvento><dhRegEvento>2026-11-24T10:05:05-03:00</dhRegEvento><nProt>135260000000999</nProt></infEvento></retEventoCTe></procEventoCTe>)

    transport.answer(:distribution, ret_dist(docs: [
      ["000000000000001", "procCTe_v4.00.xsd", proc_xml],
      ["000000000000002", "procEventoCTe_v4.00.xsd", ev_xml]
    ], last_nsu: "000000000000002", max_nsu: "000000000000002"))

    result = client.distribute!(after: 0)
    expect(result).to be_success
    expect(result).not_to be_more
    expect(result.retry_at).not_to be_nil
    expect(result.documents.size).to eq(2)

    waybill_doc, event_doc = result.documents
    expect(waybill_doc).to be_waybill
    expect(waybill_doc.key).to eq(signed.key)
    expect(waybill_doc.service_value).to eq(BigDecimal("500.00"))
    expect(waybill_doc.cargo_value).to eq(BigDecimal("15000.00"))
    expect(waybill_doc.modal).to eq("01")
    expect(waybill_doc.filename).to eq("#{signed.key}-procCTe.xml")

    expect(event_doc).to be_event
    expect(event_doc.type).to eq("110111")
    expect(event_doc.sequence).to eq(1)
    expect(event_doc.filename).to eq("#{signed.key}_110111_001-procEventoCTe.xml")

    call = transport.calls.first
    expect(call.url).to eq("https://hom1.cte.fazenda.gov.br/CTeDistribuicaoDFe/CTeDistribuicaoDFe.asmx")
    expect(call.operation).to eq("cteDistDFeInteresse")
    expect(call.xml).to include("<cUFAutor>35</cUFAutor>")
    expect(client.endpoint.request_wrapper).to eq("cteDistDFeInteresse")
    expect(client.endpoint.request_tag).to eq("cteDadosMsg")
  end

  it "fetches a specific NSU and raises on consumption block" do
    transport.answer(:distribution, ret_dist(code: 137, message: "Nenhum documento", last_nsu: "000000000000005", max_nsu: "000000000000005"))
    res = client.fetch_nsu(5)
    expect(res).to be_empty
    expect(transport.calls.first.xml).to include("<consNSU><NSU>000000000000005</NSU></consNSU>")

    transport.replace(:distribution, ret_dist(code: 656, message: "Consumo indevido", last_nsu: nil, max_nsu: nil))
    expect { client.distribute! }.to raise_error(DfeRb::Cte::ConsumptionBlocked)
  end

  it "enforces docZip NSU presence, uniqueness, cursor ordering, and consNSU correlation" do
    signed = cte_client.sign(road_waybill(cte_client))
    proc_xml = DfeRb::Cte::Proc.cte(signed.xml, prot_cte(signed.key, digest: signed.digest_value))

    [
      ret_dist(docs: [[nil, "procCTe_v4.00.xsd", proc_xml]]),
      ret_dist(docs: [["000000000000000", "procCTe_v4.00.xsd", proc_xml]]),
      ret_dist(docs: [["000000000000001", "procCTe_v4.00.xsd", proc_xml], ["000000000000001", "procCTe_v4.00.xsd", proc_xml]], last_nsu: "000000000000002", max_nsu: "000000000000002"),
      ret_dist(docs: [["000000000000001", "procCTe_v4.00.xsd", proc_xml]], last_nsu: nil, max_nsu: nil),
      ret_dist(docs: [["000000000000001", "procCTe_v4.00.xsd", proc_xml]], last_nsu: "000000000000005", max_nsu: "000000000000002"),
      ret_dist(docs: [["000000000000003", "procCTe_v4.00.xsd", proc_xml]], last_nsu: "000000000000002", max_nsu: "000000000000005")
    ].each do |bad|
      transport.replace(:distribution, bad)
      expect { client.distribute }.to raise_error(DfeRb::Cte::Distribution::InvalidResponse)
    end

    transport.replace(:distribution, ret_dist(docs: [["000000000000009", "procCTe_v4.00.xsd", proc_xml]], last_nsu: nil, max_nsu: nil))
    expect { client.fetch_nsu(5) }.to raise_error(DfeRb::Cte::Distribution::InvalidResponse, /differs from requested/)

    transport.replace(:distribution, ret_dist(docs: [["000000000000005", "procCTe_v4.00.xsd", proc_xml]], last_nsu: nil, max_nsu: nil))
    expect(client.fetch_nsu(5).documents.first.nsu).to eq("000000000000005")
  end

  it "parses NT 2026.005 SN events, redacted autXML docs, CT-e OS/GTV-e as UnknownDocument, and fails atomically on corrupt docZip" do
    key = cte_key
    sn_event = %(<procEventoCTe xmlns="#{cte_ns}" versao="4.00"><eventoCTe versao="4.00"><infEvento Id="ID412140#{key}001"><cOrgao>91</cOrgao><tpAmb>2</tpAmb><CNPJ>#{cte_issuer}</CNPJ><chCTe>#{key}</chCTe><dhEvento>2026-11-24T10:05:00-03:00</dhEvento><tpEvento>412140</tpEvento><nSeqEvento>1</nSeqEvento><detEvento versaoEvento="4.00"><evTributacaoSN><descEvento>Tributacao do Simples Nacional</descEvento><nProt>135260000000123</nProt></evTributacaoSN></detEvento></infEvento></eventoCTe><retEventoCTe versao="4.00"><infEvento><tpAmb>2</tpAmb><verAplic>RFB</verAplic><cOrgao>91</cOrgao><cStat>135</cStat><xMotivo>Evento registrado</xMotivo><chCTe>#{key}</chCTe><tpEvento>412140</tpEvento><nSeqEvento>1</nSeqEvento><dhRegEvento>2026-11-24T10:05:05-03:00</dhRegEvento><nProt>135260000000999</nProt></infEvento></retEventoCTe></procEventoCTe>)
    canc_sn = sn_event.gsub("412140", "412141").sub("evTributacaoSN", "evCancTribSN").sub("/evTributacaoSN", "/evCancTribSN")
    redacted_cte = %(<cteProc xmlns="#{cte_ns}" versao="4.00"><CTe><infCte Id="CTe#{key}" versao="4.00"><ide><UFIni>SP</UFIni><UFFim>RJ</UFFim></ide></infCte></CTe>#{prot_cte(key)}</cteProc>)
    cte_os_key = cte_key(model: 67)
    cte_os = %(<cteOSProc xmlns="#{cte_ns}" versao="4.00"><CTeOS><infCte Id="CTe#{cte_os_key}" versao="4.00"/></CTeOS>#{prot_cte(cte_os_key)}</cteOSProc>)
    gtve_key = cte_key(model: 64)
    gtve = %(<gtveProc xmlns="#{cte_ns}" versao="4.00"><GTVe><infCte Id="CTe#{gtve_key}" versao="4.00"/></GTVe>#{prot_cte(gtve_key)}</gtveProc>)

    transport.answer(:distribution, ret_dist(docs: [
      ["000000000000001", "procEventoCTe_v4.00.xsd", sn_event],
      ["000000000000002", "procEventoCTe_v4.00.xsd", canc_sn],
      ["000000000000003", "procCTe_v4.00.xsd", redacted_cte],
      ["000000000000004", "procCTeOS_v4.00.xsd", cte_os],
      ["000000000000005", "procGTVe_v4.00.xsd", gtve]
    ], last_nsu: "000000000000005", max_nsu: "000000000000005"))

    docs = client.distribute.documents
    expect(docs.map(&:kind)).to eq(%i[event event waybill unknown unknown])
    expect(docs[0].type).to eq("412140")
    expect(docs[1].type).to eq("412141")
    expect(docs[2].issuer_tax_id).to be_nil
    expect(docs[3].key).to eq(cte_os_key)
    expect(docs[4].key).to eq(gtve_key)

    corrupt_batch = ret_dist(docs: [
      ["000000000000001", "procCTe_v4.00.xsd", redacted_cte],
      ["000000000000002", "procCTe_v4.00.xsd", "<broken"]
    ], last_nsu: "000000000000002", max_nsu: "000000000000002")
    transport.replace(:distribution, corrupt_batch)
    expect { client.distribute }.to raise_error(DfeRb::Cte::Distribution::InvalidResponse) { |err|
      expect(err.nsu).to eq("000000000000002")
      expect(err.schema).to eq("procCTe_v4.00.xsd")
      expect(err.response_xml).to eq(corrupt_batch)
    }
  end
end
