# Shared helpers for the NFS-e specs: a transport that answers like the Sefin Nacional and
# the ADN, a ready DPS and the NFS-e the Sefin would generate from it.
module NfseHelpers
  PROVIDER = "11444777000161"
  TAKER = "11222333000181"
  CITY = "5002704" # Campo Grande/MS

  # Records each request and answers from a queue per service, matched by URL.
  class FakeRest
    Call = Struct.new(:method, :url, :body)

    PATTERNS = {
      issue: %r{/nfse\z}, consult: %r{/nfse/[0-9A-Z]{50}\z}, dps: %r{/dps/DPS}, event: %r{/nfse/[0-9A-Z]{50}/eventos\z},
      event_query: %r{/eventos/\d+/\d+\z}, distribution: %r{/contribuintes/DFe/}, events: %r{/contribuintes/NFSe/},
      agreement: %r{/convenio\z}, rates: %r{/aliquota\z}
    }.freeze

    attr_reader :calls

    def initialize
      @calls = []
      @answers = Hash.new { |hash, key| hash[key] = [] }
    end

    # status and json, an exception, or a callable taking the request body.
    def answer(service, *responses)
      @answers[service].concat(responses)
      self
    end

    def request(method, url, body = nil)
      @calls << Call.new(method, url, body)
      service = PATTERNS.find { |_, pattern| url.split("?").first.match?(pattern) }&.first or raise "no service for #{url}"
      queue = @answers[service]
      raise "no answer queued for #{service}" if queue.empty?

      response = (queue.size > 1) ? queue.shift : queue.first
      response = response.call(body) if response.respond_to?(:call)
      raise response if response.is_a?(Exception)

      status, json = response
      DfeRb::Nfse::Transport::Reply.new(status: status, json: json, body: json && JSON.generate(json))
    end

    def calls_to(service) = @calls.select { |call| call.url.split("?").first.match?(PATTERNS.fetch(service)) }
  end

  def nfse_certificate(cnpj: PROVIDER) = DfeRb::Certificate.from_pkcs12(pkcs12_der(cnpj: cnpj), "cert-pass")

  def nfse_client(transport = FakeRest.new, **options)
    DfeRb::Nfse::Client.new(certificate: nfse_certificate, city: CITY, transport: transport, **options)
  end

  def taker_address = {street: "Rua B", number: "1", district: "Centro", city_code: CITY, zip: "79002-000"}

  # A software house of the Simples Nacional billing a company in its city.
  def service_declaration(builder = DfeRb::Nfse::Declaration, number: 1, **options, &block)
    build = builder.respond_to?(:build_declaration) ? builder.method(:build_declaration) : builder.method(:new)
    options = {city: CITY}.merge(options) unless builder.respond_to?(:build_declaration)
    build.call(**options) do |dps|
      dps.number number
      dps.provider cnpj: PROVIDER, simples: :me_epp, simples_regime: :simples, special_regime: :none
      dps.taker cnpj: TAKER, name: "CLIENTE SA", address: taker_address
      dps.service national_code: "010101", description: "Desenvolvimento de software sob encomenda", city_code: CITY, nbs: "115021000"
      dps.amount "1000.00"
      dps.issqn :taxable
      dps.withholding :none
      dps.approximate_taxes simples_rate: "6.00"
      dps.ibs_cbs operation_indicator: "030101", cst: "000", class_code: "000001"
      block&.call(dps)
    end
  end

  # A document as the APIs answer it: GZip in Base64, as is.
  def gzip64(xml)
    buffer = StringIO.new("".b)
    Zlib::GzipWriter.new(buffer).tap { |gzip| gzip.write(xml) }.close
    Base64.strict_encode64(buffer.string)
  end

  def nfse_key(number: 1) = "#{CITY}21#{PROVIDER}#{number.to_s.rjust(13, "0")}26111234567890"

  # The <NFSe> the Sefin would generate around a signed DPS.
  def nfse_xml(signed_xml, key: nfse_key)
    dps = signed_xml.sub(/\A<\?xml[^>]*\?>/, "")
    %(<NFSe xmlns="#{DfeRb::Nfse::NAMESPACE}" versao="1.01"><infNFSe Id="NFS#{key}"><xLocEmi>Campo Grande</xLocEmi>) +
      %(<nNFSe>1</nNFSe><cStat>100</cStat><dhProc>2026-11-18T10:00:01-04:00</dhProc>) +
      %(<valores><vBC>1000.00</vBC><pAliqAplic>2.00</pAliqAplic><vISSQN>20.00</vISSQN><vLiq>1000.00</vLiq></valores>#{dps}</infNFSe></NFSe>)
  end

  def issued_answer(signed_xml, key: nfse_key)
    [201, {"tipoAmbiente" => 2, "versaoAplicativo" => "SefinNacional_1.6.0", "dataHoraProcessamento" => "2026-11-18T10:00:01-04:00",
           "idDps" => DfeRb::Nfse::Document.new(signed_xml).id, "chaveAcesso" => key, "nfseXmlGZipB64" => gzip64(nfse_xml(signed_xml, key: key)),
           "alertas" => [{"codigo" => "A0001", "descricao" => "Alerta de teste"}]}]
  end

  def rejected_answer(code, description = "Rejeitada")
    [400, {"tipoAmbiente" => 2, "versaoAplicativo" => "SefinNacional_1.6.0", "dataHoraProcessamento" => "2026-11-18T10:00:01-04:00",
           "erros" => [{"codigo" => code, "descricao" => description}]}]
  end

  def error_answer(status, code, description = "Erro")
    [status, {"tipoAmbiente" => 2, "dataHoraProcessamento" => "2026-11-18T10:00:01-04:00", "erro" => {"codigo" => code, "descricao" => description}}]
  end
end

RSpec.configure do |config|
  config.include NfseHelpers
end
