RSpec.describe DfeRb::Nfe::Endpoints do
  def url(uf, env, service) = described_class.resolve(uf: uf, environment: env, service: service).url

  it "resolves the SP authorizer per environment" do
    expect(url("SP", :production, :authorization)).to eq("https://nfe.fazenda.sp.gov.br/ws/nfeautorizacao4.asmx")
    expect(url("SP", :homologacao, :authorization)).to eq("https://homologacao.nfe.fazenda.sp.gov.br/ws/nfeautorizacao4.asmx")
  end

  it "routes states without their own authorizer to SVRS or SVAN" do
    expect(url("RJ", :production, :status)).to eq("https://nfe.svrs.rs.gov.br/ws/NfeStatusServico/NfeStatusServico4.asmx")
    expect(url("RJ", :homologacao, :status)).to eq("https://nfe-homologacao.svrs.rs.gov.br/ws/NfeStatusServico/NfeStatusServico4.asmx")
    expect(url("MA", :production, :authorization)).to eq("https://www.sefazvirtual.fazenda.gov.br/NFeAutorizacao4/NFeAutorizacao4.asmx")
    expect(url("MA", :homologacao, :authorization)).to eq("https://hom.sefazvirtual.fazenda.gov.br/NFeAutorizacao4/NFeAutorizacao4.asmx")
  end

  it "keeps each authorizer's own path style" do
    expect(url("AM", :production, :consult)).to eq("https://nfe.sefaz.am.gov.br/services2/services/NfeConsulta4")
    expect(url("MG", :production, :event)).to eq("https://nfe.fazenda.mg.gov.br/nfe2/services/NFeRecepcaoEvento4")
    expect(url("BA", :production, :inutilization)).to eq("https://nfe.sefaz.ba.gov.br/webservices/NFeInutilizacao4/NFeInutilizacao4.asmx")
  end

  it "defines every service for every authorizer in both environments" do
    described_class::AUTHORIZERS.keys.each do |authorizer|
      uf = DfeRb::Nfe::States::CODES.keys.find { |code| DfeRb::Nfe::States.authorizer(code) == authorizer }
      described_class::SERVICE_KEYS.each do |service|
        %i[production homologacao].each do |env|
          expect(url(uf, env, service)).to start_with("https://"), "#{authorizer} #{env} #{service}"
        end
      end
    end
  end

  it "carries the SOAP namespace and operation" do
    endpoint = described_class.resolve(uf: "SP", environment: :production, service: :authorization)

    expect(endpoint.namespace).to eq("http://www.portalfiscal.inf.br/nfe/wsdl/NFeAutorizacao4")
    expect(endpoint.operation).to eq("nfeAutorizacaoLote")
    expect(endpoint.authorizer).to eq("SP")
  end

  it "lets the caller override a URL" do
    endpoint = described_class.resolve(uf: "SP", environment: :production, service: :status,
      overrides: {status: "https://proxy.example/status"})

    expect(endpoint.url).to eq("https://proxy.example/status")
  end

  it "rejects unknown services and environments" do
    expect { described_class.resolve(uf: "SP", environment: :production, service: :nope) }.to raise_error(ArgumentError, /unknown service/)
    expect { described_class.resolve(uf: "SP", environment: :moon, service: :status) }.to raise_error(ArgumentError, /unknown environment/)
  end

  it "accepts environment aliases and tpAmb codes" do
    expect(DfeRb::Environment.normalize("hom")).to eq(:homologacao)
    expect(DfeRb::Environment.normalize(1)).to eq(:production)
    expect(DfeRb::Environment.normalize("2")).to eq(:homologacao)
    expect(DfeRb::Environment.code(:production)).to eq("1")
  end
end
