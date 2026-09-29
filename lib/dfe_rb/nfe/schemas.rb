require "nokogiri"

module DfeRb
  module Nfe
    # Compiled XSDs bundled with the gem, one per root document. Each root is compiled on its
    # own because some SEFAZ schemas define the same type names (e.g. TProtNFe) differently.
    module Schemas
      DIRECTORY = File.expand_path("../xml/schemas/nfe_4.00", __dir__)
      DUMMY_SIGNATURE = <<~XML.delete("\n").freeze
        <Signature xmlns="http://www.w3.org/2000/09/xmldsig#"><SignedInfo>
        <CanonicalizationMethod Algorithm="http://www.w3.org/TR/2001/REC-xml-c14n-20010315"/>
        <SignatureMethod Algorithm="http://www.w3.org/2000/09/xmldsig#rsa-sha1"/>
        <Reference URI="#NFe"><Transforms>
        <Transform Algorithm="http://www.w3.org/2000/09/xmldsig#enveloped-signature"/>
        <Transform Algorithm="http://www.w3.org/TR/2001/REC-xml-c14n-20010315"/></Transforms>
        <DigestMethod Algorithm="http://www.w3.org/2000/09/xmldsig#sha1"/><DigestValue>AAAAAAAAAAAAAAAAAAAAAAAAAAA=</DigestValue>
        </Reference></SignedInfo><SignatureValue>AAAA</SignatureValue>
        <KeyInfo><X509Data><X509Certificate>AAAA</X509Certificate></X509Data></KeyInfo></Signature>
      XML

      @compiled = {}
      @lock = Mutex.new

      class << self
        # The compiled schema for a root file such as "nfe_v4.00.xsd".
        def compile(file)
          @lock.synchronize do
            @compiled[file] ||= begin
              path = File.join(DIRECTORY, file)
              Nokogiri::XML::Schema.from_document(Nokogiri::XML(File.read(path), path))
            end
          end
        end

        # Messages for everything in `xml` (an <NFe> element) that breaks the NF-e 4.00 schema.
        # An unsigned NFe is checked with a placeholder signature, since <Signature> is
        # mandatory in the schema.
        def nfe_issues(xml)
          document = xml.include?("<Signature") ? xml : xml.sub(%r{</NFe>\s*\z}, "#{DUMMY_SIGNATURE}</NFe>")
          parsed = Nokogiri::XML(document)
          compile("nfe_v4.00.xsd").validate(parsed).map { |error| readable(error) }
        rescue Nokogiri::XML::SyntaxError => e
          ["not well-formed XML: #{e.message}"]
        end

        private

        # libxml2 says "Element '{ns}vNF': [facet 'pattern'] The value 'x' is not accepted by
        # the pattern '...'": drop the namespace noise and keep the line.
        def readable(error)
          error.message.gsub("{http://www.portalfiscal.inf.br/nfe}", "").gsub("{http://www.w3.org/2000/09/xmldsig#}", "ds:")
        end
      end
    end
  end
end
