RSpec.describe DfeRb::Nfce::Endpoints do
  def url(uf, env, service) = described_class.resolve(uf: uf, environment: env, service: service).url

  it "sends a state with its own NFC-e authorizer there, at the NFC-e's own addresses" do
    expect(url("MS", :homologacao, :authorization)).to eq("https://hom.nfce.sefaz.ms.gov.br/ws/NFeAutorizacao4")
    expect(url("SP", :production, :consult)).to eq("https://nfce.fazenda.sp.gov.br/ws/NFeConsultaProtocolo4.asmx")
    expect(url("MG", :homologacao, :status)).to eq("https://hnfce.fazenda.mg.gov.br/nfce/services/NFeStatusServico4")
    expect(url("AM", :production, :event)).to eq("https://nfce.sefaz.am.gov.br/nfce-services/services/RecepcaoEvento4")
  end

  it "sends every other state to the SVRS, BA, PE and MA included" do
    %w[BA PE MA RJ SC].each do |state|
      expect(DfeRb::Nfce::States.authorizer(state)).to eq("SVRS")
    end
    expect(url("BA", :homologacao, :status)).to eq("https://nfce-homologacao.svrs.rs.gov.br/ws/NfeStatusServico/NfeStatusServico4.asmx")
  end

  it "defines every service for every authorizer in both environments" do
    described_class::AUTHORIZERS.each_key do |authorizer|
      uf = DfeRb::States::CODES.keys.find { |code| DfeRb::Nfce::States.authorizer(code) == authorizer }
      described_class::SERVICE_KEYS.each do |service|
        %i[production homologacao].each do |env|
          expect(url(uf, env, service)).to start_with("https://"), "#{authorizer} #{env} #{service}"
        end
      end
    end
  end

  it "carries the NF-e's SOAP namespace and operation" do
    endpoint = described_class.resolve(uf: "MS", environment: :homologacao, service: :authorization)

    expect(endpoint.namespace).to eq("http://www.portalfiscal.inf.br/nfe/wsdl/NFeAutorizacao4")
    expect(endpoint.operation).to eq("nfeAutorizacaoLote")
    expect(endpoint.authorizer).to eq("MS")
  end

  it "takes overrides" do
    endpoint = described_class.resolve(uf: "MS", environment: :production, service: :status, overrides: {status: "https://proxy/s"})
    expect(endpoint.url).to eq("https://proxy/s")
  end

  it "knows every state's QR code and consultation addresses in both environments" do
    DfeRb::States::CODES.each_key do |state|
      %i[production homologacao].each do |env|
        expect(described_class.qr_code(uf: state, environment: env)).to match(%r{\Ahttps?://}), "#{state} #{env}"
        expect(described_class.consult_url(uf: state, environment: env).length).to be_between(21, 85), "#{state} #{env}"
      end
    end
    expect(described_class.qr_code(uf: "MS", environment: :homologacao)).to eq("http://www.dfe.ms.gov.br/nfce/qrcode")
    expect(described_class.consult_url(uf: "SP", environment: :production)).to eq("https://www.nfce.fazenda.sp.gov.br/consulta")
    expect(described_class.qr_code(uf: "SP", environment: :production, overrides: {qr_code: "https://x/q"})).to eq("https://x/q")
  end
end
