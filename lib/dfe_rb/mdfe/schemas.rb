module DfeRb
  module Mdfe
    # Validation against the bundled MDF-e 3.00 XSDs (DfeRb::Xsd).
    module Schemas
      PACKAGE = "mdfe_3.00"
      DUMMY_SIGNATURE = <<~XML.delete("\n").freeze
        <Signature xmlns="http://www.w3.org/2000/09/xmldsig#"><SignedInfo>
        <CanonicalizationMethod Algorithm="http://www.w3.org/TR/2001/REC-xml-c14n-20010315"/>
        <SignatureMethod Algorithm="http://www.w3.org/2000/09/xmldsig#rsa-sha1"/>
        <Reference URI="#MDFe"><Transforms>
        <Transform Algorithm="http://www.w3.org/2000/09/xmldsig#enveloped-signature"/>
        <Transform Algorithm="http://www.w3.org/TR/2001/REC-xml-c14n-20010315"/></Transforms>
        <DigestMethod Algorithm="http://www.w3.org/2000/09/xmldsig#sha1"/><DigestValue>AAAAAAAAAAAAAAAAAAAAAAAAAAA=</DigestValue>
        </Reference></SignedInfo><SignatureValue>AAAA</SignatureValue>
        <KeyInfo><X509Data><X509Certificate>AAAA</X509Certificate></X509Data></KeyInfo></Signature>
      XML
      # Detail schema of each event type.
      EVENTS = {
        "110111" => "evCancMDFe_v3.00.xsd", "110112" => "evEncMDFe_v3.00.xsd",
        "110114" => "evIncCondutorMDFe_v3.00.xsd", "110115" => "evInclusaoDFeMDFe_v3.00.xsd"
      }.freeze

      module_function

      # Messages for everything in `xml` (an <MDFe> element) that breaks the layout: the
      # general schema and then the modal's own, which the general one doesn't look into
      # (rej. 580). An unsigned MDFe is checked with a placeholder signature, since
      # <Signature> is mandatory in the schema.
      def mdfe_issues(xml)
        source = xml.include?("<Signature") ? xml : xml.sub(%r{</MDFe>\s*\z}, "#{DUMMY_SIGNATURE}</MDFe>")
        document = Nokogiri::XML(source) { |config| config.strict.nonet }
        general = Xsd.issues(document, package: PACKAGE, file: "mdfe_v3.00.xsd")
        general.empty? ? modal_issues(document) : general
      rescue Nokogiri::XML::SyntaxError => e
        ["not well-formed XML: #{e.message}"]
      end

      # Messages for a signed <eventoMDFe>: the event's schema and its detail's.
      def event_issues(xml)
        document = Nokogiri::XML(xml) { |config| config.strict.nonet }
        general = Xsd.issues(document, package: PACKAGE, file: "eventoMDFe_v3.00.xsd")
        return general unless general.empty?

        type = document.at_xpath("//mdfe:infEvento/mdfe:tpEvento", Signature::NAMESPACES)&.text
        file = EVENTS[type] or return ["tpEvento #{type} has no known detail schema"]
        detail = document.at_xpath("//mdfe:detEvento/*", Signature::NAMESPACES) or return ["detEvento is empty"]
        Xsd.issues(standalone(detail), package: PACKAGE, file: file)
      rescue Nokogiri::XML::SyntaxError => e
        ["not well-formed XML: #{e.message}"]
      end

      def modal_issues(document)
        modal = document.at_xpath("/mdfe:MDFe/mdfe:infMDFe/mdfe:infModal/*", Signature::NAMESPACES)
        return ["infModal: the modal's group is missing"] unless modal

        file, = Schema::MODALS[modal.name]
        return ["infModal: <#{modal.name}> is not a modal (#{Schema::MODALS.keys.join(", ")})"] unless file

        Xsd.issues(standalone(modal), package: PACKAGE, file: file)
      end

      # `node` as the root of a document of its own, namespace declarations included.
      def standalone(node)
        Nokogiri::XML::Document.new.tap { |document| document.root = node.dup }
      end
    end
  end
end
