module DistributionHelpers
  DIST_NS = "http://www.portalfiscal.inf.br/nfe"

  def ecpf_certificate(cpf: "52998224725")
    company = nfe_certificate
    cert = company.certificate.dup
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=CPF TEST")
    factory = OpenSSL::X509::ExtensionFactory.new(cert, cert)
    cert.add_extension(factory.create_extension("subjectAltName", "otherName:2.16.76.1.3.1;UTF8:01011980#{cpf}000000000000000000000"))
    cert.sign(company.private_key, OpenSSL::Digest.new("SHA256"))
    DfeRb::Certificate.new(certificate: cert, private_key: company.private_key)
  end

  def distribution_response(docs = [], code: 138, last: "10", max: "20", environment: "2")
    zipped = docs.each_with_index.map do |entry, index|
      xml, schema, nsu = entry
      io = StringIO.new
      Zlib::GzipWriter.wrap(io) { |gzip| gzip.write(xml) }
      attr = (nsu == false) ? "" : %( NSU="#{nsu || format("%015d", index + 1)}")
      %(<docZip#{attr} schema="#{schema}">#{Base64.strict_encode64(io.string)}</docZip>)
    end.join
    %(<retDistDFeInt xmlns="#{DIST_NS}" versao="1.01"><tpAmb>#{environment}</tpAmb><verAplic>AN_TEST</verAplic>) +
      %(<cStat>#{code}</cStat><xMotivo>Resposta SEFAZ</xMotivo><dhResp>2026-09-29T10:00:00-03:00</dhResp>) +
      %(#{"<ultNSU>#{last}</ultNSU>" if last}#{"<maxNSU>#{max}</maxNSU>" if max}) +
      %(#{"<loteDistDFeInt>#{zipped}</loteDistDFeInt>" unless zipped.empty?}</retDistDFeInt>)
  end

  def invoice_summary_xml(key: Fixtures::ACO_KEY, situation: 1)
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <resNFe xmlns="#{DIST_NS}" versao="1.01">
        <chNFe>#{key}</chNFe><CNPJ>99888777000100</CNPJ><xNome>Emitente &amp; Filhos</xNome>
        <IE>123456789</IE><dhEmi>2026-09-29T09:00:00-03:00</dhEmi><tpNF>1</tpNF><vNF>123.45</vNF>
        <dhRecbto>2026-09-29T09:00:05-03:00</dhRecbto><nProt>135260000000001</nProt><cSitNFe>#{situation}</cSitNFe>
      </resNFe>
    XML
  end

  def event_summary_xml(type: "610600", sequence: 1)
    %(<resEvento xmlns="#{DIST_NS}" versao="1.01"><cOrgao>91</cOrgao><CNPJ>99888777000100</CNPJ>) +
      %(<chNFe>#{Fixtures::ACO_KEY}</chNFe><dhEvento>2026-09-29T10:00:00-03:00</dhEvento>) +
      %(<tpEvento>#{type}</tpEvento><nSeqEvento>#{sequence}</nSeqEvento><xEvento>Evento do Fisco</xEvento>) +
      %(<dhRecbto>2026-09-29T10:00:05-03:00</dhRecbto><nProt>135260000000002</nProt></resEvento>)
  end

  def distributed_invoice_xml(version: "4.00", key: Fixtures::ACO_KEY)
    time = (version == "2.00") ? "<dEmi>2015-01-02</dEmi>" : "<dhEmi>2026-09-29T10:00:00-03:00</dhEmi>"
    %(<nfeProc xmlns="#{DIST_NS}" versao="#{version}"><NFe><infNFe Id="NFe#{key}" versao="#{version}">) +
      %(<ide>#{time}</ide><emit><CNPJ>99888777000100</CNPJ><xNome>Emitente</xNome></emit>) +
      %(<dest><CNPJ>#{Fixtures::HR_CNPJ}</CNPJ></dest><total><ICMSTot><vNF>123.45</vNF></ICMSTot></total></infNFe></NFe>) +
      prot_nfe(key) + "</nfeProc>"
  end

  def manifestation_response(events = [], lot_code: 128, environment: "2", codes: {})
    entries = events.map do |event|
      code = codes.fetch(event.identity, 135)
      %(<retEvento versao="1.00"><infEvento><tpAmb>#{environment}</tpAmb><verAplic>AN_TEST</verAplic><cOrgao>91</cOrgao>) +
        %(<cStat>#{code}</cStat><xMotivo>Resultado do evento</xMotivo><chNFe>#{event.key}</chNFe><tpEvento>#{event.type}</tpEvento>) +
        %(<nSeqEvento>#{event.sequence}</nSeqEvento><dhRegEvento>2026-09-29T10:02:00-03:00</dhRegEvento>) +
        %(#{"<nProt>135260000000999</nProt>" if [135, 136].include?(code)}</infEvento></retEvento>)
    end.join
    %(<retEnvEvento xmlns="#{DIST_NS}" versao="1.00"><idLote>1</idLote><tpAmb>#{environment}</tpAmb>) +
      %(<verAplic>AN_TEST</verAplic><cOrgao>91</cOrgao><cStat>#{lot_code}</cStat><xMotivo>Resposta do lote</xMotivo>#{entries}</retEnvEvento>)
  end
end

RSpec.configure { |config| config.include DistributionHelpers }
