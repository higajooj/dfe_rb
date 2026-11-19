require "spec_helper"

RSpec.describe DfeRb::Nfse::Note do
  def received_xml(iss_withholding: "2", pis_cofins: "3", federal: true, taker: true)
    tribfed = <<~XML if federal
      <tribFed>
        <piscofins><CST>01</CST><vBCPisCofins>2000.00</vBCPisCofins><pAliqPis>0.65</pAliqPis><pAliqCofins>3.00</pAliqCofins>
          <vPis>13.00</vPis><vCofins>60.00</vCofins><tpRetPisCofins>#{pis_cofins}</tpRetPisCofins></piscofins>
        <vRetCP>220.00</vRetCP><vRetIRRF>30.00</vRetIRRF><vRetCSLL>20.00</vRetCSLL>
      </tribFed>
    XML
    toma = <<~XML if taker
      <toma><CNPJ>11222333000181</CNPJ><IM>12345</IM><xNome>CLIENTE SA</xNome>
        <end><endNac><cMun>5002704</cMun><CEP>79002000</CEP></endNac><xLgr>Rua B</xLgr><nro>1</nro><xBairro>Centro</xBairro></end>
        <email>contas@cliente.example</email></toma>
    XML
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <NFSe xmlns="http://www.sped.fazenda.gov.br/nfse" versao="1.01">
        <infNFSe Id="NFS500270421114447770001610000000000000126111234567890">
          <xLocEmi>Campo Grande</xLocEmi><xLocPrestacao>Campo Grande</xLocPrestacao><nNFSe>12</nNFSe>
          <cLocIncid>5002704</cLocIncid><xLocIncid>Campo Grande</xLocIncid>
          <xTribNac>Instalação e montagem de aparelhos, máquinas e equipamentos</xTribNac>
          <verAplic>SefinNac_1.6</verAplic><ambGer>2</ambGer><tpEmis>1</tpEmis><cStat>100</cStat>
          <dhProc>2026-11-18T10:00:01-04:00</dhProc><nDFSe>99</nDFSe>
          <emit><CNPJ>11444777000161</CNPJ><IM>98765</IM><xNome>INSTALADORA LTDA</xNome>
            <enderNac><xLgr>Rua A</xLgr><nro>10</nro><xBairro>Centro</xBairro><cMun>5002704</cMun><UF>MS</UF><CEP>79002000</CEP></enderNac>
            <email>fiscal@instaladora.example</email></emit>
          <valores><vBC>2000.00</vBC><pAliqAplic>5.00</pAliqAplic><vISSQN>100.00</vISSQN><vTotalRet>443.00</vTotalRet><vLiq>1507.00</vLiq></valores>
          <DPS versao="1.01"><infDPS Id="DPS500270421114447770001610000100000000000012">
            <tpAmb>2</tpAmb><dhEmi>2026-11-18T09:59:00-04:00</dhEmi><verAplic>app</verAplic><serie>1</serie><nDPS>12</nDPS>
            <dCompet>2026-11-17</dCompet><tpEmit>1</tpEmit><cLocEmi>5002704</cLocEmi>
            <prest><CNPJ>11444777000161</CNPJ><regTrib><opSimpNac>1</opSimpNac><regEspTrib>0</regEspTrib></regTrib></prest>
            #{toma}
            <serv><locPrest><cLocPrestacao>5002704</cLocPrestacao></locPrest>
              <cServ><cTribNac>140601</cTribNac><cTribMun>001</cTribMun><xDescServ>Instalação de ar-condicionado</xDescServ><cNBS>120012300</cNBS></cServ></serv>
            <valores><vServPrest><vServ>2050.00</vServ></vServPrest><vDescCondIncond><vDescIncond>50.00</vDescIncond></vDescCondIncond>
              <trib><tribMun><tribISSQN>1</tribISSQN><tpRetISSQN>#{iss_withholding}</tpRetISSQN></tribMun>#{tribfed}
                <totTrib><indTotTrib>0</indTotTrib></totTrib></trib></valores>
          </infDPS></DPS>
        </infNFSe>
      </NFSe>
    XML
  end

  subject(:note) { described_class.new(received_xml) }

  it "reads the parties: the provider from emit, the taker from the DPS" do
    expect(note.provider).to have_attributes(tax_id: "11444777000161", name: "INSTALADORA LTDA", municipal_registration: "98765",
      city_code: "5002704", email: "fiscal@instaladora.example", nif: nil)
    expect(note.taker).to have_attributes(tax_id: "11222333000181", name: "CLIENTE SA", municipal_registration: "12345",
      city_code: "5002704", email: "contas@cliente.example")
    expect(note.intermediary).to be_nil
    expect(described_class.new(received_xml(taker: false)).taker).to be_nil
  end

  it "reads the service, its dates and its identity" do
    expect(note.service).to have_attributes(national_code: "140601", municipal_code: "001", description: "Instalação de ar-condicionado",
      nbs: "120012300", city_code: "5002704", national_name: "Instalação e montagem de aparelhos, máquinas e equipamentos")
    expect(note.issued_at).to eq(Time.iso8601("2026-11-18T09:59:00-04:00"))
    expect(note.competence_on).to eq(Date.new(2026, 11, 17))
    expect([note.series, note.dps_number, note.number, note.environment]).to eq(%w[1 12 12 2])
    expect(note.incidence_city_code).to eq("5002704")
  end

  it "reads the values as BigDecimal" do
    expect(note.service_amount).to eq(BigDecimal(2050))
    expect(note.unconditional_discount).to eq(BigDecimal(50))
    expect(note.conditional_discount).to eq(0)
    expect(note.net_amount).to eq("1507.00")
  end

  it "reads what the taker withheld, the PIS and the COFINS by tpRetPisCofins" do
    expect(note.iss_withholding).to eq(:taker)
    expect(note.iss_withheld?).to be(true)
    expect(note.withheld.to_h).to eq(iss: BigDecimal(100), social_security: BigDecimal(220), irrf: BigDecimal(30),
      csll: BigDecimal(20), pis: BigDecimal(13), cofins: BigDecimal(60))
    expect(note.withheld.total).to eq(BigDecimal(443))
    expect(note.total_withheld).to eq(BigDecimal(443))
  end

  it "leaves out what wasn't withheld" do
    other = described_class.new(received_xml(iss_withholding: "1", pis_cofins: "2"))
    expect(other.iss_withheld?).to be(false)
    expect(other.withheld.to_h.values_at(:iss, :pis, :cofins)).to eq([0, 0, 0])
    expect(described_class.new(received_xml(pis_cofins: "6")).withheld.to_h.values_at(:pis, :cofins)).to eq([0, BigDecimal(60)])
  end

  it "sums the withholdings when the Sefin states no total" do
    plain = described_class.new(received_xml(federal: false).sub(%r{<vTotalRet>[^<]*</vTotalRet>}, ""))
    expect(plain.withheld.any?).to be(true)
    expect(plain.total_withheld).to eq(BigDecimal(100))
    expect(described_class.new(received_xml(federal: false, iss_withholding: "1")).withheld.any?).to be(false)
  end
end
