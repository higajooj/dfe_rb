# Shared helpers for the MDF-e specs: canned SEFAZ answers and ready-to-send manifests.
module MdfeHelpers
  MDFE_NS = "http://www.portalfiscal.inf.br/mdfe"
  ISSUER = "11444777000161"

  def mdfe_certificate(cnpj: ISSUER)
    DfeRb::Certificate.from_pkcs12(pkcs12_der(cnpj: cnpj), "cert-pass")
  end

  def mdfe_client(transport = FakeTransport.new, **options)
    DfeRb::Mdfe::Client.new(certificate: mdfe_certificate, uf: "SP", transport: transport, **options)
  end

  def document_key(model, number: 5, tax_id: "11222333000181", emission_type: 1, state: "SP")
    DfeRb::AccessKey.build(state: state, issued_at: Time.now, tax_id: tax_id, series: 1, number: number,
      numeric_code: "12345679", model: model, emission_type: emission_type).to_s
  end

  def issuer_address
    {street: "Rua A", number: "100", district: "Centro", city_code: "3550308", zip: "01001000"}
  end

  # A company hauling its own goods under two NF-e, in its own truck.
  def own_cargo_manifest(builder = DfeRb::Mdfe::Manifest, number: 10, **options, &block)
    build = builder.respond_to?(:build_manifest) ? builder.method(:build_manifest) : builder.method(:new)
    build.call(**options) do |mdfe|
      mdfe.series 1
      mdfe.number number
      mdfe.issuer_type :own_cargo
      mdfe.issuer tax_id: ISSUER, name: "EMPRESA TESTE LTDA", state_registration: "111111111111", address: issuer_address
      mdfe.load_at "Sao Paulo", "SP"
      mdfe.unload_at "Rio de Janeiro", "RJ", nfe: [document_key(55), document_key(55, number: 6)]
      mdfe.road do |road|
        road.vehicle plate: "ABC1D23", tare: 9000, wheels: :truck, body: :closed, state: "SP" do |vehicle|
          vehicle.driver "Fulano de Tal", "12345678909"
        end
      end
      mdfe.cargo value: "15000.00", weight: "1200.5"
      block&.call(mdfe)
    end
  end

  # A carrier hauling a full load under one CT-e, in a truck hired from an autonomous driver.
  def carrier_manifest(builder = DfeRb::Mdfe::Manifest, **options, &block)
    build = builder.respond_to?(:build_manifest) ? builder.method(:build_manifest) : builder.method(:new)
    build.call(**options) do |mdfe|
      mdfe.number 3
      mdfe.issuer_type :carrier
      mdfe.issuer tax_id: ISSUER, name: "TRANSPORTES LTDA", state_registration: "111111111111", address: issuer_address
      mdfe.load_at "Sao Paulo", "SP"
      mdfe.route "MG"
      mdfe.unload_at "Goiania", "GO", cte: [document_key(57)]
      mdfe.road do |road|
        road.rntrc "12345678"
        road.ciot "123456789012", tax_id: ISSUER
        road.freight_payment tax_id: "11222333000181", total: "1000.00", terms: :cash do |payment|
          payment.component :freight, "1000.00"
          payment.bank pix: "chave@pix.com"
        end
        road.vehicle plate: "ABC1D23", tare: 9000, wheels: :tractor, body: :none do |vehicle|
          vehicle.driver "Fulano de Tal", "12345678909"
          vehicle.owner tax_id: "12345678909", name: "Fulano de Tal", rntrc: "87654321", kind: :tac_independent
        end
      end
      mdfe.insurance responsible: :issuer, insurer: {name: "SEGURADORA SA", cnpj: "11222333000181"}, policy: "123", endorsement: "456"
      mdfe.cargo value: "15000.00", weight: 30, unit: :ton
      mdfe.main_product "Soja", kind: :bulk_solid, ncm: "12019000",
        full_load: {loading: {zip: "01001000"}, unloading: {zip: "74000000"}}
      block&.call(mdfe)
    end
  end

  # <protMDFe> as SEFAZ returns it for one manifest.
  def prot_mdfe(key, code: 100, message: "Autorizado o uso do MDF-e", protocol: "935260000000123", digest: "AAAAAAAAAAAAAAAAAAAAAAAAAAA=")
    %(<protMDFe xmlns="#{MDFE_NS}" versao="3.00"><infProt><tpAmb>2</tpAmb><verAplic>RS20260101000000</verAplic><chMDFe>#{key}</chMDFe>) +
      %(<dhRecbto>2026-09-29T10:00:05-03:00</dhRecbto>#{"<nProt>#{protocol}</nProt>" if protocol}<digVal>#{digest}</digVal>) +
      %(<cStat>#{code}</cStat><xMotivo>#{message}</xMotivo></infProt></protMDFe>)
  end

  def ret_mdfe(protocol_xml = nil, code: 100, message: "Autorizado o uso do MDF-e")
    %(<retMDFe xmlns="#{MDFE_NS}" versao="3.00"><tpAmb>2</tpAmb><cUF>43</cUF><verAplic>RS20260101000000</verAplic>) +
      %(<cStat>#{code}</cStat><xMotivo>#{message}</xMotivo>#{protocol_xml}</retMDFe>)
  end

  def ret_cons_sit_mdfe(code: 100, message: "Autorizado o uso do MDF-e", protocol_xml: nil, events: [])
    %(<retConsSitMDFe xmlns="#{MDFE_NS}" versao="3.00"><tpAmb>2</tpAmb><verAplic>RS20260101000000</verAplic><cStat>#{code}</cStat>) +
      %(<xMotivo>#{message}</xMotivo><cUF>43</cUF>#{protocol_xml}#{events.join}</retConsSitMDFe>)
  end

  def ret_cons_mdfe_nao_enc(manifests = [])
    code, message = manifests.empty? ? [112, "MDF-e nao encerrados nao localizados"] : [111, "MDF-e nao encerrados localizados"]
    listed = manifests.map { |key, protocol| "<infMDFe><chMDFe>#{key}</chMDFe><nProt>#{protocol}</nProt></infMDFe>" }.join
    %(<retConsMDFeNaoEnc xmlns="#{MDFE_NS}" versao="3.00"><tpAmb>2</tpAmb><verAplic>RS20260101000000</verAplic><cStat>#{code}</cStat>) +
      %(<xMotivo>#{message}</xMotivo><cUF>43</cUF>#{listed}</retConsMDFeNaoEnc>)
  end

  def ret_evento_mdfe(key, type:, code: 135, message: "Evento registrado e vinculado ao MDF-e", protocol: "935260000000999", sequence: 1)
    registered = protocol ? "<dhRegEvento>2026-09-29T10:02:00-03:00</dhRegEvento><nProt>#{protocol}</nProt>" : ""
    %(<retEventoMDFe xmlns="#{MDFE_NS}" versao="3.00"><infEvento><tpAmb>2</tpAmb><verAplic>RS20260101000000</verAplic>) +
      %(<cOrgao>35</cOrgao><cStat>#{code}</cStat><xMotivo>#{message}</xMotivo><chMDFe>#{key}</chMDFe><tpEvento>#{type}</tpEvento>) +
      %(<xEvento>Evento</xEvento><nSeqEvento>#{sequence}</nSeqEvento>#{registered}</infEvento></retEventoMDFe>)
  end

  def ret_cons_stat_serv_mdfe(code: 107, message: "Servico em Operacao")
    %(<retConsStatServMDFe xmlns="#{MDFE_NS}" versao="3.00"><tpAmb>2</tpAmb><verAplic>RS20260101000000</verAplic><cStat>#{code}</cStat>) +
      %(<xMotivo>#{message}</xMotivo><cUF>43</cUF><dhRecbto>2026-09-29T10:00:00-03:00</dhRecbto><tMed>1</tMed></retConsStatServMDFe>)
  end
end

RSpec.configure do |config|
  config.include MdfeHelpers
end
