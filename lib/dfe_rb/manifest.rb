module DfeRb
  class Manifest
    attr_reader :request_xml

    HOM = "https://hom.nfe.fazenda.gov.br/NFeRecepcaoEvento4/NFeRecepcaoEvento4.asmx?WSDL"
    PROD = "https://www.nfe.fazenda.gov.br/NFeRecepcaoEvento4/NFeRecepcaoEvento4.asmx?WSDL"
    MS_PROD = "https://nfe.sefaz.ms.gov.br/ws/NFeRecepcaoEvento4?WSDL"

    def initialize(keys, options = {})
      @keys = keys

      @cert = options[:cert]
      @key = options[:key]
      @cnpj = options[:cnpj]
      @amb = options[:amb]

      @savon_config = {
        wsdl: (@amb == "1") ? PROD : HOM,
        ssl_cert: @cert,
        ssl_cert_key: @key
      }.merge(DfeRb.ssl_options).merge(DfeRb.savon_log_options)

      @request_xml = generate_xml
    end

    def call
      client = Savon.client(@savon_config)
      client.call(:nfe_recepcao_evento_nf, xml: @request_xml).to_xml
    end

    private

    def generate_xml
      doc = Nokogiri::XML File.read(File.expand_path("xml/manifest.xml", __dir__))
      inf_evento = doc.at_css("xmlns|infEvento", xmlns: "http://www.portalfiscal.inf.br/nfe").to_xml

      nodes = @keys.map do |k|
        inf = Nokogiri::XML::DocumentFragment.parse inf_evento
        inf.at_css("infEvento")["Id"] = "ID#{inf.at_css("tpEvento").text}#{k}01"
        inf.at_css("tpAmb").content = @amb
        inf.at_css("CNPJ").content = @cnpj
        inf.at_css("chNFe").content = k
        inf.at_css("dhEvento").content = DateTime.now.to_s
        inf.at_css("nSeqEvento").content = 1
        inf.at_css("infEvento").wrap("<evento xmlns=\"http://www.portalfiscal.inf.br/nfe\" versao=\"1.00\"></evento>")

        sign_event_xml(inf.to_xml)
      end

      r_xml = Nokogiri::XML File.read(File.expand_path("xml/manifest.xml", __dir__))
      r_xml.css("xmlns|evento", xmlns: "http://www.portalfiscal.inf.br/nfe").remove

      parent_node = r_xml.at_css("xmlns|envEvento", xmlns: "http://www.portalfiscal.inf.br/nfe")
      nodes.each { |n| parent_node.add_child n }

      r_xml.css("xmlns|X509IssuerSerial", xmlns: "http://www.w3.org/2000/09/xmldsig#").remove

      r_xml.to_xml
    end

    def sign_event_xml event_node_xml
      s = Signer.new event_node_xml, noblanks: false, wss: false, canonicalize_algorithm: :c14n_1_0
      s.cert = @cert
      s.private_key = @key

      doc = s.document
      e = doc.at_css("xmlns|infEvento", xmlns: "http://www.portalfiscal.inf.br/nfe")

      s.security_node = doc.root
      s.digest! e, id: e["Id"], enveloped: true
      s.sign!(issuer_serial: true)

      doc.root
    end
  end
end
