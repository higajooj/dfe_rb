RSpec.describe DfeRb::Cte::Endpoints do
  describe ".resolve" do
    it "routes own-authorizer states to their own SEFAZ" do
      ep = described_class.resolve(uf: "SP", environment: :production, service: :authorization)
      expect(ep.authorizer).to eq("SP")
      expect(ep.url).to eq("https://nfe.fazenda.sp.gov.br/CTeWS/WS/CTeRecepcaoSincV4.asmx")
      expect(ep.namespace).to eq("http://www.portalfiscal.inf.br/cte/wsdl/CTeRecepcaoSincV4")
      expect(ep.operation).to eq("cteRecepcao")
      expect(ep.request_tag).to eq("cteDadosMsg")
      expect(ep.answer).to eq("retCTe")

      mg = described_class.resolve(uf: "MG", environment: :homologacao, service: :status)
      expect(mg.url).to eq("https://hcte.fazenda.mg.gov.br/cte/services/CTeStatusServicoV4")
      expect(mg.operation).to eq("cteStatusServicoCT")

      mt = described_class.resolve(uf: "MT", environment: :production, service: :consult)
      expect(mt.url).to eq("https://cte.sefaz.mt.gov.br/ctews2/services/CTeConsultaV4")

      ms = described_class.resolve(uf: "MS", environment: :production, service: :event)
      expect(ms.url).to eq("https://producao.cte.ms.gov.br/ws/CTeRecepcaoEventoV4")

      pr = described_class.resolve(uf: "PR", environment: :homologacao, service: :authorization)
      expect(pr.url).to eq("https://homologacao.cte.fazenda.pr.gov.br/cte4/CTeRecepcaoSincV4")
    end

    it "routes SVSP and SVRS states accurately" do
      pe = described_class.resolve(uf: "PE", environment: :production, service: :authorization)
      expect(pe.authorizer).to eq("SVSP")
      expect(pe.url).to eq("https://nfe.fazenda.sp.gov.br/CTeWS/WS/CTeRecepcaoSincV4.asmx")

      rj = described_class.resolve(uf: "RJ", environment: :homologacao, service: :authorization)
      expect(rj.authorizer).to eq("SVRS")
      expect(rj.url).to eq("https://cte-homologacao.svrs.rs.gov.br/ws/CTeRecepcaoSincV4/CTeRecepcaoSincV4.asmx")

      rs = described_class.resolve(uf: "RS", environment: :production, service: :status)
      expect(rs.authorizer).to eq("SVRS")
      expect(rs.url).to eq("https://cte.svrs.rs.gov.br/ws/CTeStatusServicoV4/CTeStatusServicoV4.asmx")
    end

    it "routes contingency to SVC-RS or SVC-SP per state" do
      sp_svc = described_class.resolve(uf: "SP", environment: :production, service: :authorization, contingency: true)
      expect(sp_svc.authorizer).to eq("SVC-RS")
      expect(sp_svc.url).to eq("https://cte.svrs.rs.gov.br/ws/CTeRecepcaoSincV4/CTeRecepcaoSincV4.asmx")

      rj_svc = described_class.resolve(uf: "RJ", environment: :production, service: :authorization, contingency: true)
      expect(rj_svc.authorizer).to eq("SVC-SP")
      expect(rj_svc.url).to eq("https://nfe.fazenda.sp.gov.br/CTeWS/WS/CTeRecepcaoSincV4.asmx")

      mg_svc = described_class.resolve(uf: "MG", environment: :homologacao, service: :status, contingency: true)
      expect(mg_svc.authorizer).to eq("SVC-SP")
      expect(mg_svc.url).to eq("https://homologacao.nfe.fazenda.sp.gov.br/CTeWS/WS/CTeStatusServicoV4.asmx")
    end

    it "honors URL overrides for normal and contingency services" do
      ep = described_class.resolve(uf: "SP", environment: :homologacao, service: :status,
        overrides: {status: "https://custom.example/status"})
      expect(ep.url).to eq("https://custom.example/status")

      svc = described_class.resolve(uf: "SP", environment: :homologacao, service: :status,
        overrides: {contingency: {status: "https://custom.example/svc"}}, contingency: true)
      expect(svc.url).to eq("https://custom.example/svc")
    end
  end
end

RSpec.describe DfeRb::Cte::QrCode do
  let(:key) { cte_key }

  it "builds the state authorizer's QR code URL for normal and signed contingency emission" do
    url = described_class.url(key: key, state: "SP", environment: :homologacao)
    expect(url).to eq("https://homologacao.nfe.fazenda.sp.gov.br/CTeConsulta/qrCode?chCTe=#{key}&tpAmb=2")

    cert = cte_certificate
    signed_url = described_class.url(key: key, state: "RJ", environment: :production, certificate: cert)
    parsed = described_class.parse(signed_url)
    expect(parsed[:address]).to eq("https://dfe-portal.svrs.rs.gov.br/cte/qrCode")
    expect(parsed[:key]).to eq(key)
    expect(parsed[:environment]).to eq("1")
    expect(described_class.signed_by?(key, parsed[:sign], cert.certificate)).to be(true)
  end
end
