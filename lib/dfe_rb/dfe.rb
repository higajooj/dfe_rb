module DfeRb
  class Dfe
    attr_reader :request_xml

    HOM = "https://hom.nfe.fazenda.gov.br/NFeDistribuicaoDFe/NFeDistribuicaoDFe.asmx?WSDL"
    PROD = "https://www1.nfe.fazenda.gov.br/NFeDistribuicaoDFe/NFeDistribuicaoDFe.asmx?WSDL"

    def initialize(type, options = {})
      @cert = options[:cert]
      @key = options[:key]
      @cnpj = options[:cnpj]
      @amb = options[:amb]
      @type = type
      @nsu = options[:nsu]
      @chkey = options[:chkey]

      @savon_config = {
        wsdl: (@amb == "1") ? PROD : HOM,
        ssl_cert: @cert,
        ssl_cert_key: @key
      }.merge(DfeRb.ssl_options).merge(DfeRb.savon_log_options)
    end

    def call
      client = Savon.client(@savon_config)

      doc = Nokogiri::XML File.read(File.expand_path("xml/dfe.xml", __dir__))
      doc.at_css("xmlns|CNPJ", xmlns: "http://www.portalfiscal.inf.br/nfe").content = @cnpj
      doc.at_css("xmlns|tpAmb", xmlns: "http://www.portalfiscal.inf.br/nfe").content = @amb
      if @type == :last_nsu || @type == :broad
        doc.at_css("xmlns|ultNSU", xmlns: "http://www.portalfiscal.inf.br/nfe").content = (@type == :last_nsu) ? @nsu : "000000000000000"
      else
        doc.at_css("xmlns|distNSU", xmlns: "http://www.portalfiscal.inf.br/nfe").remove

        b = Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
          case @type
          when :target_nsu
            xml.consNSU {
              xml.NSU @nsu
            }
          when :key
            xml.consChNFe {
              xml.chNFe @chkey
            }
          end
        end

        doc.at_css("xmlns|distDFeInt", xmlns: "http://www.portalfiscal.inf.br/nfe").add_child b.doc.root
      end

      @request_xml = doc.to_xml
      client.call(:nfe_dist_d_fe_interesse, xml: @request_xml).to_xml
    end
  end
end
