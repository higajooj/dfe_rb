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
      items = docs.map { |nsu, schema, xml| %(<docZip NSU="#{nsu}" schema="#{schema}">#{gzip_b64(xml)}</docZip>) }.join
      "<loteDistDFeInt>#{items}</loteDistDFeInt>"
    end
    %(<retDistDFeInt xmlns="#{cte_ns}" versao="1.00"><tpAmb>2</tpAmb><verAplic>1.0.0</verAplic><cStat>#{code}</cStat>) +
      %(<xMotivo>#{message}</xMotivo><dhResp>2026-11-24T12:00:00</dhResp><ultNSU>#{last_nsu}</ultNSU><maxNSU>#{max_nsu}</maxNSU>#{lote}</retDistDFeInt>)
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

    transport.replace(:distribution, ret_dist(code: 656, message: "Consumo indevido"))
    expect { client.distribute! }.to raise_error(DfeRb::Cte::ConsumptionBlocked)
  end
end
