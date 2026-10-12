require "nokogiri"

module DfeRb
  # The official XSDs bundled with the gem, compiled on first use. Each root file is compiled
  # on its own because some SEFAZ schemas define the same type names differently.
  module Xsd
    DIRECTORY = File.expand_path("xml/schemas", __dir__)

    @compiled = {}
    @lock = Mutex.new

    module_function

    # The compiled schema of `file` in the bundled `package` ("mdfe_3.00", "mdfe_v3.00.xsd").
    def compile(package, file)
      @lock.synchronize do
        @compiled[[package, file]] ||= begin
          path = File.join(DIRECTORY, package, file)
          Nokogiri::XML::Schema.from_document(Nokogiri::XML(File.read(path), path) { |config| config.strict.nonet })
        end
      end
    end

    # Messages for everything in `xml` (a String or a parsed document) that breaks the schema.
    def issues(xml, package:, file:)
      document = xml.is_a?(String) ? Nokogiri::XML(xml) { |config| config.strict.nonet } : xml
      compile(package, file).validate(document).map { |error| readable(error) }
    rescue Nokogiri::XML::SyntaxError => e
      ["not well-formed XML: #{e.message}"]
    end

    # libxml2 says "Element '{ns}vNF': [facet 'pattern'] The value 'x' is not accepted by the
    # pattern '...'": drop the namespace noise and keep the line.
    def readable(error)
      error.message.strip.gsub(%r{\{http://www\.portalfiscal\.inf\.br/\w+\}}, "").gsub("{http://www.w3.org/2000/09/xmldsig#}", "ds:")
    end
  end
end
