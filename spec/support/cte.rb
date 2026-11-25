module CteHelpers
  CTE_NS = "http://www.portalfiscal.inf.br/cte"
  CTE_ISSUER = "11444777000161"
  CTE_SENDER = "11222333000181"
  CTE_RECIPIENT = "33000167000101"

  def cte_ns = CTE_NS
  def cte_issuer = CTE_ISSUER
  def cte_sender = CTE_SENDER
  def cte_recipient = CTE_RECIPIENT

  def cte_certificate(cnpj: CTE_ISSUER)
    DfeRb::Certificate.from_pkcs12(pkcs12_der(cnpj: cnpj), "cert-pass")
  end

  def cte_client(transport = FakeTransport.new, uf: "SP", **options)
    DfeRb::Cte::Client.new(certificate: cte_certificate, uf: uf, transport: transport, **options)
  end

  def cte_key(model: 57, number: 42, tax_id: CTE_ISSUER, emission_type: 1, state: "SP", series: 1, numeric_code: "12345679", issued_at: Time.now)
    DfeRb::AccessKey.build(
      state: state, issued_at: issued_at, tax_id: tax_id, series: series, number: number,
      numeric_code: numeric_code, model: model, emission_type: emission_type
    ).to_s
  end

  def cte_sp_address
    {street: "Rua A", number: "100", district: "Centro", city_code: "3550308", zip: "01001000"}
  end

  def cte_rj_address
    {street: "Rua B", number: "200", district: "Centro", city_code: "3304557", zip: "20000000"}
  end

  def road_waybill(builder = DfeRb::Cte::Waybill, number: 42, ibs_cbs: {class_code: "000001"}, **options, &block)
    build = builder.respond_to?(:build_waybill) ? builder.method(:build_waybill) : builder.method(:new)
    build.call(**options) do |cte|
      cte.number number
      cte.cfop "6353"
      cte.nature_of_operation "Prestacao de servico de transporte"
      cte.issuer tax_id: CTE_ISSUER, name: "TRANSPORTES LTDA", state_registration: "111111111111",
        tax_regime: :normal, address: cte_sp_address
      cte.sender tax_id: CTE_SENDER, name: "REMETENTE SA", state_registration: "222222222222",
        address: cte_sp_address
      cte.recipient tax_id: CTE_RECIPIENT, name: "DESTINATARIO SA", state_registration: "333333333333",
        address: cte_rj_address
      cte.taker :sender
      cte.freight total: "500.00" do |f|
        f.component "FRETE VALOR", "500.00"
      end
      cte.icms cst: "00", rate: "12.00"
      cte.ibs_cbs(**ibs_cbs) if ibs_cbs
      cte.cargo value: "15000.00", product: "Eletronicos" do |c|
        c.measure :kg, "1200.5"
      end
      cte.nfe cte_key(model: 55, tax_id: CTE_SENDER)
      cte.road rntrc: "12345678"
      block&.call(cte)
    end
  end

  def prot_cte(key, code: 100, message: "Autorizado o uso do CT-e", protocol: "135260000000123", digest: "AAAAAAAAAAAAAAAAAAAAAAAAAAA=", environment: "2", received_at: "2026-11-24T10:00:05-03:00")
    %(<protCTe xmlns="#{CTE_NS}" versao="4.00"><infProt><tpAmb>#{environment}</tpAmb><verAplic>SP_CTe_PL_009</verAplic><chCTe>#{key}</chCTe>) +
      %(#{"<dhRecbto>#{received_at}</dhRecbto>" if received_at}#{"<nProt>#{protocol}</nProt>" if protocol}#{"<digVal>#{digest}</digVal>" if digest}) +
      %(<cStat>#{code}</cStat><xMotivo>#{message}</xMotivo></infProt></protCTe>)
  end

  def ret_cte(protocol_xml = nil, code: 100, message: "Autorizado o uso do CT-e", environment: "2")
    %(<retCTe xmlns="#{CTE_NS}" versao="4.00"><tpAmb>#{environment}</tpAmb><cUF>35</cUF><verAplic>SP_CTe_PL_009</verAplic>) +
      %(<cStat>#{code}</cStat><xMotivo>#{message}</xMotivo>#{protocol_xml}</retCTe>)
  end

  def ret_cons_sit_cte(code: 100, message: "Autorizado o uso do CT-e", protocol_xml: nil, events: [], environment: "2")
    %(<retConsSitCTe xmlns="#{CTE_NS}" versao="4.00"><tpAmb>#{environment}</tpAmb><verAplic>SP_CTe_PL_009</verAplic><cStat>#{code}</cStat>) +
      %(<xMotivo>#{message}</xMotivo><cUF>35</cUF>#{protocol_xml}#{events.join}</retConsSitCTe>)
  end

  def ret_evento_cte(key, type:, code: 135, message: "Evento registrado e vinculado a CT-e", protocol: "135260000000999", sequence: 1, environment: "2", registered_at: "2026-11-24T10:02:00-03:00", include_correlation: true)
    correlation = include_correlation ? %(<chCTe>#{key}</chCTe><tpEvento>#{type}</tpEvento><xEvento>Evento</xEvento><nSeqEvento>#{sequence}</nSeqEvento>) : ""
    registered = +""
    registered << "<dhRegEvento>#{registered_at}</dhRegEvento>" if registered_at
    registered << "<nProt>#{protocol}</nProt>" if protocol
    %(<retEventoCTe xmlns="#{CTE_NS}" versao="4.00"><infEvento><tpAmb>#{environment}</tpAmb><verAplic>SP_CTe_PL_009</verAplic>) +
      %(<cOrgao>35</cOrgao><cStat>#{code}</cStat><xMotivo>#{message}</xMotivo>#{correlation}#{registered}</infEvento></retEventoCTe>)
  end

  def ret_cons_stat_serv_cte(code: 107, message: "Servico em Operacao")
    %(<retConsStatServCTe xmlns="#{CTE_NS}" versao="4.00"><tpAmb>2</tpAmb><verAplic>SP_CTe_PL_009</verAplic><cStat>#{code}</cStat>) +
      %(<xMotivo>#{message}</xMotivo><cUF>35</cUF><dhRecbto>2026-11-24T10:00:00-03:00</dhRecbto><tMed>1</tMed></retConsStatServCTe>)
  end
end

RSpec.configure do |config|
  config.include CteHelpers
end
