require "nokogiri"

module DfeRb
  # Reads SEFAZ answers. Element lookups ignore namespaces; fragments that must be kept
  # (protNFe, retEvento...) are copied with their namespace declarations intact. A subclass
  # gives the document's NAMESPACE.
  class Response
    attr_reader :xml, :plain

    def initialize(xml)
      @xml = xml
      @namespaced = Nokogiri::XML(xml)
      @plain = Nokogiri::XML(xml).tap(&:remove_namespaces!)
    end

    def root_name = @plain.root&.name

    # Text of the first element at a tag path such as "infProt/cStat" (no CSS or XPath syntax).
    def text(path, from: @plain)
      from.at_xpath("//" + path.split("/").join("/"))&.text&.strip
    end

    def code = text("cStat")&.to_i

    def message = text("xMotivo")

    # A copy of the first `tag` element, namespaces preserved, as XML.
    def fragment(tag, from: @namespaced)
      node = from.at_xpath("//doc:#{tag}", namespaces) or return
      node.dup.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
    end

    def fragments(tag)
      @namespaced.xpath("//doc:#{tag}", namespaces).map do |node|
        node.dup.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
      end
    end

    def nodes(tag) = @plain.xpath("//#{tag}")

    private

    def namespaces = {"doc" => self.class::NAMESPACE}
  end
end
