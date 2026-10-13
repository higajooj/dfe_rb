RSpec.describe DfeRb::Mdfe::Client, "over SOAP" do
  let(:client) { DfeRb::Mdfe::Client.new(certificate: mdfe_certificate, uf: "SP") }
  let(:signed) { client.sign(own_cargo_manifest(client)) }

  def soap(operation, service, content)
    %(<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body>) +
      %(<#{operation}Result xmlns="http://www.portalfiscal.inf.br/mdfe/wsdl/#{service}">#{content}</#{operation}Result></soap:Body></soap:Envelope>)
  end

  it "sends the manifest compressed in <mdfeDadosMsg> and reads the answer by its root" do
    sent = nil
    stub = stub_request(:post, "https://mdfe-homologacao.svrs.rs.gov.br/ws/MDFeRecepcaoSinc/MDFeRecepcaoSinc.asmx")
      .with(headers: {"Content-Type" => %(application/soap+xml; charset=utf-8; action="http://www.portalfiscal.inf.br/mdfe/wsdl/MDFeRecepcaoSinc/mdfeRecepcao")}) { |request|
        message = Nokogiri::XML(request.body).at_xpath("/*[local-name()='Envelope']/*[local-name()='Body']/*")
        sent = DfeRb::Mdfe::Requests.unpack(message.text)
        message.name == "mdfeDadosMsg" && message.namespace.href == "http://www.portalfiscal.inf.br/mdfe/wsdl/MDFeRecepcaoSinc" &&
          message.element_children.empty?
      }
      .to_return(status: 200, body: soap("mdfeRecepcao", "MDFeRecepcaoSinc", ret_mdfe(prot_mdfe(signed.key, digest: signed.digest_value))))

    result = client.authorize(signed)

    expect(stub).to have_been_requested
    expect(sent).to eq(signed.xml)
    expect(result).to be_authorized
    expect(result.protocol_xml).to eq(prot_mdfe(signed.key, digest: signed.digest_value))
  end

  it "sends the other requests as plain XML" do
    stub = stub_request(:post, "https://mdfe-homologacao.svrs.rs.gov.br/ws/MDFeStatusServico/MDFeStatusServico.asmx")
      .with { |request| request.body.include?(%(<mdfeDadosMsg xmlns="http://www.portalfiscal.inf.br/mdfe/wsdl/MDFeStatusServico"><consStatServMDFe)) }
      .to_return(status: 200, body: soap("mdfeStatusServicoMDF", "MDFeStatusServico", ret_cons_stat_serv_mdfe))

    expect(client.status).to be_online
    expect(stub).to have_been_requested
  end

  it "sends the distribution request unwrapped and reads its offsetless dhResp as UTC" do
    stub = stub_request(:post, "https://mdfe-homologacao.svrs.rs.gov.br/ws/MDFeDistribuicaoDFe/MDFeDistribuicaoDFe.asmx")
      .with { |request|
        request.body.include?(%(<soap12:Body><mdfeDadosMsg xmlns="http://www.portalfiscal.inf.br/mdfe/wsdl/MDFeDistribuicaoDFe"><distDFeInt))
      }
      .to_return(status: 200, body: soap("mdfeDistDFeInteresse", "MDFeDistribuicaoDFe",
        %(<retDistDFeInt xmlns="#{MdfeHelpers::MDFE_NS}" versao="1.00"><tpAmb>2</tpAmb><verAplic>RS</verAplic><cStat>137</cStat>) +
        %(<xMotivo>Nenhum documento localizado</xMotivo><dhResp>2026-09-29T13:00:00</dhResp><ultNSU>0</ultNSU><maxNSU>0</maxNSU></retDistDFeInt>)))

    result = DfeRb::Mdfe::Distribution::Client.new(certificate: mdfe_certificate).distribute

    expect(result).to be_empty
    expect(result.responded_at).to eq(Time.utc(2026, 9, 29, 13))
    expect(stub).to have_been_requested
  end

  it "reports a SOAP fault as a transport error" do
    stub_request(:post, /MDFeConsulta/).to_return(status: 500, body: %(<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body>) +
      %(<soap:Fault><soap:Reason><soap:Text>Server was unable to process request</soap:Text></soap:Reason></soap:Fault></soap:Body></soap:Envelope>))

    expect { client.consult(signed.key) }.to raise_error(DfeRb::TransportError, /SOAP fault: Server was unable/)
  end
end
