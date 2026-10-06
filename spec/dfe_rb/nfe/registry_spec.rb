RSpec.describe "Consulta cadastro" do
  let(:transport) { NfeHelpers::FakeTransport.new }
  let(:client) { nfe_client(transport) }

  def ret_cons_cad(code: 111, message: "Consulta cadastro com uma ocorrencia", entries: "")
    %(<retConsCad xmlns="#{NfeHelpers::NFE_NS}" versao="2.00"><infCons><verAplic>MS_NFe_1.1.37</verAplic><cStat>#{code}</cStat>) +
      %(<xMotivo>#{message}</xMotivo><UF>MS</UF><CNPJ>11222333000181</CNPJ><dhCons>2026-10-06T15:53:44-04:00</dhCons><cUF>50</cUF>) +
      %(#{entries}</infCons></retConsCad>)
  end

  let(:entry) do
    "<infCad><IE>282567143</IE><CNPJ>11222333000181</CNPJ><UF>MS</UF><cSit>1</cSit><indCredNFe>1</indCredNFe><indCredCTe>4</indCredCTe>" \
      "<xNome>CLIENTE LTDA</xNome><xFant>CLIENTE</xFant><xRegApur>Regime de tributacao normal</xRegApur><CNAE>4744001</CNAE>" \
      "<dIniAtiv>1989-02-15</dIniAtiv><dUltSit>2026-08-14</dUltSit><ender><xLgr>AVENIDA A</xLgr><nro>1315</nro>" \
      "<xBairro>CENTRO</xBairro><cMun>5007901</cMun><xMun>Sidrolândia </xMun><CEP>79170000</CEP></ender></infCad>"
  end

  it "asks the consulted state and reads its registrations" do
    transport.answer(:registry, ret_cons_cad(entries: entry))

    result = client.taxpayers(uf: "MS", cnpj: "11.222.333/0001-81")

    call = transport.calls.first
    expect(call.url).to eq("https://hom.nfe.sefaz.ms.gov.br/ws/CadConsultaCadastro4")
    expect(call.operation).to eq("consultaCadastro")
    expect(call.xml).to eq(%(<ConsCad xmlns="#{NfeHelpers::NFE_NS}" versao="2.00"><infCons><xServ>CONS-CAD</xServ><UF>MS</UF>) +
      %(<CNPJ>11222333000181</CNPJ></infCons></ConsCad>))
    expect(result).to be_found
    expect(result.code).to eq(111)
    expect(result.state).to eq("MS")
    expect(result.request_xml).to eq(call.xml)
    taxpayer = result.taxpayers.first
    expect(taxpayer).to be_active
    expect(taxpayer).to have_attributes(state_registration: "282567143", cnpj: "11222333000181", cpf: nil, tax_id: "11222333000181",
      state: "MS", nfe_accreditation: 1, cte_accreditation: 4, name: "CLIENTE LTDA", trade_name: "CLIENTE",
      regime: "Regime de tributacao normal", cnae: "4744001", started_on: Date.new(1989, 2, 15),
      situation_changed_on: Date.new(2026, 8, 14), closed_on: nil, single_state_registration: nil)
    expect(taxpayer.address).to eq(street: "AVENIDA A", number: "1315", district: "CENTRO", city_code: "5007901", city: "Sidrolândia",
      zip: "79170000")
  end

  it "asks by CPF or IE too, and by one of them only" do
    transport.answer(:registry, ret_cons_cad)

    client.taxpayers(uf: "MS", ie: "28.256.714-3")
    client.taxpayers(uf: "MS", cpf: "111.444.777-35")

    expect(transport.calls.map(&:xml)).to match([include("<IE>282567143</IE>"), include("<CPF>11144477735</CPF>")])
    expect { client.taxpayers(uf: "MS") }.to raise_error(ArgumentError, /one of cnpj:, cpf: or ie:/)
    expect { client.taxpayers(uf: "MS", cnpj: "1", ie: "2") }.to raise_error(ArgumentError, /one of/)
    expect { client.taxpayers(uf: "MS", cnpj: "não é") }.to raise_error(DfeRb::ValidationError)
  end

  it "reports a taxpayer the state doesn't have as a result" do
    transport.answer(:registry, ret_cons_cad(code: 259, message: "Rejeicao: CNPJ da consulta nao cadastrado como contribuinte na UF"))

    result = client.taxpayers(uf: "MS", cnpj: "11222333000181")

    expect(result).not_to be_found
    expect(result.taxpayers).to eq([])
  end

  describe "endpoints" do
    def registry(uf, env = :production) = DfeRb::Nfe::Endpoints.registry(uf: uf, environment: env)

    it "are the state's own, or the SVRS's for the states it serves" do
      expect(registry("SP").url).to eq("https://nfe.fazenda.sp.gov.br/ws/cadconsultacadastro4.asmx")
      expect(registry("SC").url).to eq("https://cad.svrs.rs.gov.br/ws/cadconsultacadastro/cadconsultacadastro4.asmx")
      expect(registry("RS", :homologacao).url).to eq("https://cad-homologacao.svrs.rs.gov.br/ws/cadconsultacadastro/cadconsultacadastro4.asmx")
      expect(registry("SC").authorizer).to eq("SVRS")
      expect(registry("SP").namespace).to eq("http://www.portalfiscal.inf.br/nfe/wsdl/CadConsultaCadastro4")
    end

    it "wrap the request for MT only" do
      expect(registry("MT").request_wrapper).to eq("consultaCadastro")
      expect(registry("MS").request_wrapper).to be_nil
    end

    it "don't exist for states without the service, unless given" do
      expect(DfeRb::Nfe::Endpoints.registry?("RJ")).to be(false)
      expect { client.taxpayers(uf: "RJ", cnpj: "11222333000181") }.to raise_error(DfeRb::Nfe::Unsupported, /RJ offers no consulta cadastro/)
      expect(DfeRb::Nfe::Endpoints.registry(uf: "RJ", environment: :production, overrides: {registry: "https://proxy"}).url).to eq("https://proxy")
    end
  end

  describe "the answer's envelope" do
    def envelope(body) = %(<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body>#{body}</soap:Body></soap:Envelope>)

    it "is read whatever each state wraps it in" do
      ns = "http://www.portalfiscal.inf.br/nfe/wsdl/CadConsultaCadastro4"
      answer = ret_cons_cad(code: 259, message: "nao cadastrado")
      bodies = [
        %(<nfeResultMsg xmlns="#{ns}">#{answer}</nfeResultMsg>),
        %(<nfeResultMsg xmlns="#{ns}"><consultaCadastroResult>#{answer}</consultaCadastroResult></nfeResultMsg>),
        %(<consultaCadastro4Result xmlns="#{ns}">#{answer}</consultaCadastro4Result>)
      ]

      bodies.each do |body|
        xml = DfeRb::Transport.extract_result(envelope(body), answer: "retConsCad")
        expect(DfeRb::Nfe::Registry.parse(xml).code).to eq(259)
      end
      expect { DfeRb::Transport.extract_result(envelope("<other/>"), answer: "retConsCad") }
        .to raise_error(DfeRb::TransportError, /no unambiguous <retConsCad>/)
    end
  end
end
