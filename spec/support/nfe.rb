# Shared helpers for the NF-e specs: a transport that never touches the network, canned SEFAZ
# answers, and a ready-to-send invoice.
module NfeHelpers
  NFE_NS = "http://www.portalfiscal.inf.br/nfe"

  # Records what was sent per service and answers from a queue (strings or callables).
  class FakeTransport
    Call = Struct.new(:service, :url, :operation, :xml)

    attr_reader :calls

    def initialize
      @calls = []
      @answers = Hash.new { |hash, key| hash[key] = [] }
    end

    def answer(service, *responses)
      @answers[service].concat(responses)
      self
    end

    # Replaces whatever was queued for the service.
    def replace(service, *responses)
      @answers[service] = responses
      self
    end

    def post(endpoint, xml)
      @calls << Call.new(endpoint.service, endpoint.url, endpoint.operation, xml)
      queue = @answers[endpoint.service]
      raise "no answer queued for #{endpoint.service}" if queue.empty?

      response = (queue.size > 1) ? queue.shift : queue.first
      response = response.call(xml) if response.respond_to?(:call)
      raise response if response.is_a?(Exception)

      response
    end

    def calls_to(service) = @calls.select { |call| call.service == service }
  end

  def nfe_certificate(cnpj: "11444777000161")
    DfeRb::Certificate.from_pkcs12(pkcs12_der(cnpj: cnpj), "cert-pass")
  end

  def nfe_client(transport, **options)
    DfeRb::Nfe::Client.new(certificate: nfe_certificate, uf: "SP", transport: transport, sleeper: ->(_seconds) {}, **options)
  end

  def simples_invoice(client, number: 1, payment: [:money, "20.00"], &block)
    client.build_invoice do |nfe|
      nfe.series 1
      nfe.number number
      nfe.nature_of_operation "Venda de mercadoria"
      nfe.issuer tax_id: "11.444.777/0001-61", name: "EMPRESA TESTE LTDA", state_registration: "111111111111", tax_regime: :simples,
        address: {street: "Rua A", number: "100", district: "Centro", city_code: "3550308", city: "Sao Paulo", state: "SP", zip: "01001000"}
      nfe.recipient cnpj: "11222333000181", name: "CLIENTE",
        address: {street: "Rua B", number: "1", district: "Centro", city_code: "3304557", city: "Rio de Janeiro", state: "RJ", zip: "20000000"}
      nfe.item do |i|
        i.code "1"
        i.description "Produto"
        i.ncm "84713012"
        i.cfop "6102"
        i.unit "UN"
        i.quantity 2
        i.unit_price "10.00"
        i.icms csosn: "102", origin: :domestic
        i.pis cst: "07"
        i.cofins cst: "07"
      end
      nfe.payment(*payment) if payment
      block&.call(nfe)
    end
  end

  # <protNFe> as SEFAZ returns it for one note.
  def prot_nfe(key, code: 100, message: "Autorizado o uso da NF-e", protocol: "135260000000123", digest: "AAAAAAAAAAAAAAAAAAAAAAAAAAA=", alerts: [])
    cmsg = alerts.map { |alert| "<cMsg>#{alert[:code]}</cMsg><xMsg>#{alert[:message]}</xMsg>" }.join
    %(<protNFe xmlns="#{NFE_NS}" versao="4.00"><infProt><tpAmb>2</tpAmb><verAplic>SP_NFE_PL009_V4</verAplic><chNFe>#{key}</chNFe>) +
      %(<dhRecbto>2026-09-29T10:00:05-03:00</dhRecbto>#{"<nProt>#{protocol}</nProt>" if protocol}<digVal>#{digest}</digVal>) +
      %(<cStat>#{code}</cStat><xMotivo>#{message}</xMotivo>#{cmsg}</infProt></protNFe>)
  end

  # Synchronous answer to a one-note lot.
  def ret_env_nfe_sync(protocol_xml, code: 104, message: "Lote processado")
    %(<retEnviNFe xmlns="#{NFE_NS}" versao="4.00"><tpAmb>2</tpAmb><verAplic>SP_NFE_PL009_V4</verAplic><cStat>#{code}</cStat>) +
      %(<xMotivo>#{message}</xMotivo><cUF>35</cUF><dhRecbto>2026-09-29T10:00:05-03:00</dhRecbto>#{protocol_xml}</retEnviNFe>)
  end

  # Lot-level answer without protocols (received asynchronously, or rejected as a whole).
  def ret_env_nfe(code: 103, message: "Lote recebido com sucesso", receipt: "351000000012345")
    info = receipt ? "<infRec><nRec>#{receipt}</nRec><tMed>1</tMed></infRec>" : ""
    %(<retEnviNFe xmlns="#{NFE_NS}" versao="4.00"><tpAmb>2</tpAmb><verAplic>SP_NFE_PL009_V4</verAplic><cStat>#{code}</cStat>) +
      %(<xMotivo>#{message}</xMotivo><cUF>35</cUF><dhRecbto>2026-09-29T10:00:05-03:00</dhRecbto>#{info}</retEnviNFe>)
  end

  def ret_cons_reci_nfe(protocols = [], code: 104, message: "Lote processado")
    %(<retConsReciNFe xmlns="#{NFE_NS}" versao="4.00"><tpAmb>2</tpAmb><verAplic>SP_NFE_PL009_V4</verAplic><nRec>351000000012345</nRec>) +
      %(<cStat>#{code}</cStat><xMotivo>#{message}</xMotivo><cUF>35</cUF><dhRecbto>2026-09-29T10:00:06-03:00</dhRecbto>#{protocols.join}</retConsReciNFe>)
  end

  def ret_cons_sit_nfe(key, code: 100, message: "Autorizado o uso da NF-e", protocol_xml: nil, events: [])
    %(<retConsSitNFe xmlns="#{NFE_NS}" versao="4.00"><tpAmb>2</tpAmb><verAplic>SP_NFE_PL009_V4</verAplic><cStat>#{code}</cStat>) +
      %(<xMotivo>#{message}</xMotivo><cUF>35</cUF><dhRecbto>2026-09-29T10:01:00-03:00</dhRecbto><chNFe>#{key}</chNFe>#{protocol_xml}#{events.join}</retConsSitNFe>)
  end

  def ret_env_evento(key, type:, code: 135, message: "Evento registrado e vinculado a NF-e", protocol: "135260000000999", sequence: 1)
    %(<retEnvEvento xmlns="#{NFE_NS}" versao="1.00"><idLote>1</idLote><tpAmb>2</tpAmb><verAplic>SP_NFE_PL009_V4</verAplic>) +
      %(<cOrgao>35</cOrgao><cStat>128</cStat><xMotivo>Lote de Evento Processado</xMotivo>) +
      %(<retEvento versao="1.00"><infEvento><tpAmb>2</tpAmb><verAplic>SP_NFE_PL009_V4</verAplic><cOrgao>35</cOrgao>) +
      %(<cStat>#{code}</cStat><xMotivo>#{message}</xMotivo><chNFe>#{key}</chNFe><tpEvento>#{type}</tpEvento>) +
      %(<xEvento>Evento</xEvento><nSeqEvento>#{sequence}</nSeqEvento><dhRegEvento>2026-09-29T10:02:00-03:00</dhRegEvento>) +
      %(<nProt>#{protocol}</nProt></infEvento></retEvento></retEnvEvento>)
  end

  def ret_inut_nfe(code: 102, message: "Inutilizacao de numero homologado", protocol: "135260000000777")
    %(<retInutNFe xmlns="#{NFE_NS}" versao="4.00"><infInut><tpAmb>2</tpAmb><verAplic>SP_NFE_PL009_V4</verAplic>) +
      %(<cStat>#{code}</cStat><xMotivo>#{message}</xMotivo><cUF>35</cUF><ano>26</ano><CNPJ>11444777000161</CNPJ><mod>55</mod>) +
      %(<serie>1</serie><nNFIni>10</nNFIni><nNFFin>12</nNFFin><dhRecbto>2026-09-29T10:03:00-03:00</dhRecbto>) +
      %(#{"<nProt>#{protocol}</nProt>" if protocol}</infInut></retInutNFe>)
  end

  def ret_cons_stat_serv(code: 107, message: "Servico em Operacao")
    %(<retConsStatServ xmlns="#{NFE_NS}" versao="4.00"><tpAmb>2</tpAmb><verAplic>SP_NFE_PL009_V4</verAplic><cStat>#{code}</cStat>) +
      %(<xMotivo>#{message}</xMotivo><cUF>35</cUF><dhRecbto>2026-09-29T10:00:00-03:00</dhRecbto><tMed>1</tMed></retConsStatServ>)
  end
end

RSpec.configure do |config|
  config.include NfeHelpers
end
