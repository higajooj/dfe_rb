RSpec.describe DfeRb::Cte::Client, "over SOAP 1.2" do
  let(:client) { DfeRb::Cte::Client.new(certificate: cte_certificate, uf: "SP") }
  let(:signed) { client.sign(road_waybill(client)) }

  def soap(operation, service, content)
    %(<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body>) +
      %(<#{operation}Result xmlns="http://www.portalfiscal.inf.br/cte/wsdl/#{service}">#{content}</#{operation}Result></soap:Body></soap:Envelope>)
  end

  it "sends compressed authorization in <cteDadosMsg> with the SOAP 1.2 action and extracts <retCTe>" do
    sent = nil
    stub = stub_request(:post, "https://homologacao.nfe.fazenda.sp.gov.br/CTeWS/WS/CTeRecepcaoSincV4.asmx")
      .with(headers: {"Content-Type" => %(application/soap+xml; charset=utf-8; action="http://www.portalfiscal.inf.br/cte/wsdl/CTeRecepcaoSincV4/cteRecepcao")}) { |request|
        message = Nokogiri::XML(request.body).at_xpath("/*[local-name()='Envelope']/*[local-name()='Body']/*")
        sent = DfeRb::Cte::Requests.unpack(message.text)
        message.name == "cteDadosMsg" && message.namespace.href == "http://www.portalfiscal.inf.br/cte/wsdl/CTeRecepcaoSincV4" &&
          message.element_children.empty?
      }
      .to_return(status: 200, body: soap("cteRecepcao", "CTeRecepcaoSincV4", ret_cte(prot_cte(signed.key, digest: signed.digest_value))))

    result = client.authorize!(signed)

    expect(stub).to have_been_requested
    expect(sent).to eq(signed.xml)
    expect(result).to be_authorized
    expect(result.protocol_xml).to eq(prot_cte(signed.key, digest: signed.digest_value))
  end

  it "routes SVC-RS (SP) and SVC-SP (MG) over SOAP 1.2 with the exact action URI" do
    svc_rs = client.sign(road_waybill(client) { |cte| cte.contingency :svc })
    stub_rs = stub_request(:post, "https://cte-homologacao.svrs.rs.gov.br/ws/CTeRecepcaoSincV4/CTeRecepcaoSincV4.asmx")
      .with(headers: {"Content-Type" => %(application/soap+xml; charset=utf-8; action="http://www.portalfiscal.inf.br/cte/wsdl/CTeRecepcaoSincV4/cteRecepcao")})
      .to_return(status: 200, body: soap("cteRecepcao", "CTeRecepcaoSincV4", ret_cte(prot_cte(svc_rs.key, digest: svc_rs.digest_value))))

    expect(client.authorize!(svc_rs)).to be_authorized
    expect(stub_rs).to have_been_requested

    mg_client = DfeRb::Cte::Client.new(certificate: cte_certificate, uf: "MG")
    svc_sp = mg_client.sign(road_waybill(mg_client) do |cte|
      cte.issuer tax_id: cte_issuer, name: "TRANSPORTES LTDA", state_registration: "111111111111",
        tax_regime: :normal, address: {street: "Rua A", number: "100", district: "Centro", city_code: "3106200", zip: "30100000"}
      cte.origin "3106200"
      cte.contingency :svc
    end)
    stub_sp = stub_request(:post, "https://homologacao.nfe.fazenda.sp.gov.br/CTeWS/WS/CTeRecepcaoSincV4.asmx")
      .with(headers: {"Content-Type" => %(application/soap+xml; charset=utf-8; action="http://www.portalfiscal.inf.br/cte/wsdl/CTeRecepcaoSincV4/cteRecepcao")})
      .to_return(status: 200, body: soap("cteRecepcao", "CTeRecepcaoSincV4", ret_cte(prot_cte(svc_sp.key, digest: svc_sp.digest_value))))

    expect(mg_client.authorize!(svc_sp)).to be_authorized
    expect(stub_sp).to have_been_requested
  end

  it "sends signed events in <cteDadosMsg> whose extracted payload verifies cleanly" do
    extracted_event = nil
    stub = stub_request(:post, "https://homologacao.nfe.fazenda.sp.gov.br/CTeWS/WS/CTeRecepcaoEventoV4.asmx")
      .with(headers: {"Content-Type" => %(application/soap+xml; charset=utf-8; action="http://www.portalfiscal.inf.br/cte/wsdl/CTeRecepcaoEventoV4/cteRecepcaoEvento")}) { |request|
        body_node = Nokogiri::XML(request.body).at_xpath("/*[local-name()='Envelope']/*[local-name()='Body']/*")
        payload = body_node.element_children.first
        extracted_event = payload.dup.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
        body_node.name == "cteDadosMsg" && payload.name == "eventoCTe"
      }
      .to_return(status: 200, body: soap("cteRecepcaoEvento", "CTeRecepcaoEventoV4", ret_evento_cte(signed.key, type: "110111")))

    result = client.cancel(signed.key, protocol: "135260000000123", reason: "Cancelamento por erro de digitacao")

    expect(stub).to have_been_requested
    expect(result).to be_registered
    expect(DfeRb::Cte::Signature.verify(extracted_event, id: "ID110111#{signed.key}001")).to be(true)
  end

  it "wraps CTeDistribuicaoDFe in <cteDistDFeInteresse><cteDadosMsg> and reads offsetless dhResp as UTC" do
    raw_return = %(<retDistDFeInt xmlns="#{cte_ns}" versao="1.00"><tpAmb>2</tpAmb><verAplic>AN_1.0</verAplic><cStat>137</cStat>) +
      %(<xMotivo>Nenhum documento localizado</xMotivo><dhResp>2026-11-24T13:00:00</dhResp><ultNSU>000000000000000</ultNSU><maxNSU>000000000000000</maxNSU></retDistDFeInt>)
    stub = stub_request(:post, "https://hom1.cte.fazenda.gov.br/CTeDistribuicaoDFe/CTeDistribuicaoDFe.asmx")
      .with(headers: {"Content-Type" => %(application/soap+xml; charset=utf-8; action="http://www.portalfiscal.inf.br/cte/wsdl/CTeDistribuicaoDFe/cteDistDFeInteresse")}) { |request|
        request.body.include?(%(<cteDistDFeInteresse xmlns="http://www.portalfiscal.inf.br/cte/wsdl/CTeDistribuicaoDFe"><cteDadosMsg xmlns="http://www.portalfiscal.inf.br/cte/wsdl/CTeDistribuicaoDFe"><distDFeInt))
      }
      .to_return(status: 200, body: soap("cteDistDFeInteresse", "CTeDistribuicaoDFe", raw_return))

    result = DfeRb::Cte::Distribution::Client.new(certificate: cte_certificate, uf: "SP").distribute

    expect(stub).to have_been_requested
    expect(result).to be_empty
    expect(result.responded_at).to eq(Time.utc(2026, 11, 24, 13))
    expect(result.response_xml).to include("<dhResp>2026-11-24T13:00:00</dhResp>")
  end

  it "reports a SOAP fault as a transport error" do
    stub_request(:post, /CTeConsultaV4/).to_return(status: 500, body: %(<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body>) +
      %(<soap:Fault><soap:Reason><soap:Text>Server fault</soap:Text></soap:Reason></soap:Fault></soap:Body></soap:Envelope>))

    expect { client.consult(signed.key) }.to raise_error(DfeRb::TransportError, /SOAP fault: Server fault/)
  end
end
