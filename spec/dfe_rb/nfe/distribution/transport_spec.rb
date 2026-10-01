RSpec.describe "National SOAP contracts" do
  let(:certificate) { nfe_certificate }
  let(:transport) { DfeRb::Transport.new(certificate: certificate) }
  let(:endpoint) { DfeRb::Nfe::Distribution::Endpoints.resolve(service: :distribution, environment: :homologacao) }
  let(:request_xml) { %(<distDFeInt xmlns="#{DistributionHelpers::DIST_NS}" versao="1.01"><tpAmb>2</tpAmb></distDFeInt>) }

  def soap_response(xml)
    %(<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body>) +
      %(<nfeDistDFeInteresseResponse xmlns="#{endpoint.namespace}"><nfeDistDFeInteresseResult>#{xml}</nfeDistDFeInteresseResult>) +
      %(</nfeDistDFeInteresseResponse></soap:Body></soap:Envelope>)
  end

  it "wraps nfeDadosMsg in nfeDistDFeInteresse and extracts the operation's result" do
    stub = stub_request(:post, endpoint.url).with(headers: {
      "Content-Type" => %(application/soap+xml; charset=utf-8; action="#{endpoint.namespace}/nfeDistDFeInteresse")
    }) do |request|
      doc = Nokogiri::XML(request.body)
      wrapper = doc.at_xpath("//*[local-name()='Body']/*")
      message = wrapper.at_xpath("*[local-name()='nfeDadosMsg']")
      wrapper.name == "nfeDistDFeInteresse" && wrapper.namespace.href == endpoint.namespace &&
        message.namespace.href == endpoint.namespace && message.element_children.first.name == "distDFeInt"
    end.to_return(body: soap_response(distribution_response([], code: 137)))
    result = transport.post(endpoint, request_xml)
    expect(Nokogiri::XML(result).root.name).to eq("retDistDFeInt")
    expect(stub).to have_been_requested.once
  end

  it "keeps manifestation's bare nfeDadosMsg contract and national endpoints in both environments" do
    [:production, :homologacao].each do |environment|
      ep = DfeRb::Nfe::Distribution::Endpoints.resolve(service: :manifestation, environment: environment)
      expect(ep.request_wrapper).to be_nil
      expect(ep.operation).to eq("nfeRecepcaoEventoNF")
      expect(ep.result_tag).to eq("nfeRecepcaoEventoNFResult")
      expect(ep.authorizer).to eq("AN")
      expect(ep.url).to eq("https://#{(environment == :production) ? "www" : "hom1"}.nfe.fazenda.gov.br/NFeRecepcaoEvento4/NFeRecepcaoEvento4.asmx")
      envelope = DfeRb::Transport.envelope(ep.namespace, "<envEvento/>", wrapper: ep.request_wrapper)
      expect(Nokogiri::XML(envelope).at_xpath("//*[local-name()='Body']/*").name).to eq("nfeDadosMsg")
    end
  end

  it "extracts manifestation answers from AN's nfeRecepcaoEventoNFResult body" do
    ep = DfeRb::Nfe::Distribution::Endpoints.resolve(service: :manifestation, environment: :homologacao)
    # Shape answered by hom1.nfe.fazenda.gov.br (AN_1.10.5): no nfeResultMsg element.
    body = %(<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body>) +
      %(<nfeRecepcaoEventoNFResult xmlns="#{ep.namespace}"><retEnvEvento xmlns="http://www.portalfiscal.inf.br/nfe" versao="1.00">) +
      %(<cStat>128</cStat></retEnvEvento></nfeRecepcaoEventoNFResult></soap:Body></soap:Envelope>)
    stub_request(:post, ep.url).to_return(body: body)
    expect(Nokogiri::XML(transport.post(ep, "<envEvento/>")).root.name).to eq("retEnvEvento")
  end

  it "filters docZip and signature material from logged national traffic" do
    logger = double(info: nil)
    lines = []
    allow(logger).to receive(:debug) { |&block| lines << block.call }
    response = distribution_response([["<private>BUSINESS DATA</private>", "future.xsd"]])
    encoded = Nokogiri::XML(response).at_xpath("//*[local-name()='docZip']").text
    stub_request(:post, endpoint.url).to_return(body: soap_response(response))
    DfeRb::Transport.new(certificate: certificate, logger: logger).post(endpoint, request_xml)
    expect(lines.join).to include("[FILTERED]", "<cStat>138</cStat>")
    expect(lines.join).not_to include(encoded)
  end

  it "rejects missing or ambiguous result content, DTDs and SOAP faults" do
    [soap_response(""), soap_response("<one/><two/>"),
      soap_response("<one/>").sub("</nfeDistDFeInteresseResponse>", "<nfeDistDFeInteresseResult><two/></nfeDistDFeInteresseResult></nfeDistDFeInteresseResponse>"),
      '<!DOCTYPE x [<!ENTITY x "x">]><x/>'].each do |body|
      stub_request(:post, endpoint.url).to_return(body: body)
      expect { transport.post(endpoint, request_xml) }.to raise_error(DfeRb::TransportError)
    end
    fault = '<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body><soap:Fault><soap:Reason><soap:Text>Bad message</soap:Text></soap:Reason></soap:Fault></soap:Body></soap:Envelope>'
    stub_request(:post, endpoint.url).to_return(status: 500, body: fault)
    expect { transport.post(endpoint, request_xml) }.to raise_error(DfeRb::TransportError, /Bad message/)
  end
end
