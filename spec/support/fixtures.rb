module Fixtures
  HR_CNPJ = "11444777000161"
  ACO_KEY = "50210199888777000100550010000403981000840241"

  # A retDistDFeInt response wrapping each [xml, schema] pair in a gzipped docZip.
  def build_dist_response(docs = [], stat: "138", ult_nsu: "000000000000010", max_nsu: "000000000000020", reason: "Documento(s) localizado(s)")
    zips = docs.each_with_index.map do |(xml, schema), i|
      io = StringIO.new
      gz = Zlib::GzipWriter.new(io)
      gz.write(xml)
      gz.close
      %(<docZip NSU="#{format("%015d", i + 1)}" schema="#{schema}">#{Base64.strict_encode64(io.string)}</docZip>)
    end
    <<~XML
      <retDistDFeInt xmlns="http://www.portalfiscal.inf.br/nfe" versao="1.01">
        <tpAmb>1</tpAmb>
        <cStat>#{stat}</cStat>
        <xMotivo>#{reason}</xMotivo>
        <ultNSU>#{ult_nsu}</ultNSU>
        <maxNSU>#{max_nsu}</maxNSU>
        #{"<loteDistDFeInt>#{zips.join}</loteDistDFeInt>" if zips.any?}
      </retDistDFeInt>
    XML
  end
end

RSpec.configure do |config|
  config.include Fixtures
end
