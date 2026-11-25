module DfeRb
  module Cte
    module Schemas
      PACKAGE = "cte_4.00"
      DUMMY_SIGNATURE = <<~XML.delete("\n").freeze
        <Signature xmlns="http://www.w3.org/2000/09/xmldsig#"><SignedInfo>
        <CanonicalizationMethod Algorithm="http://www.w3.org/TR/2001/REC-xml-c14n-20010315"/>
        <SignatureMethod Algorithm="http://www.w3.org/2000/09/xmldsig#rsa-sha1"/>
        <Reference URI="#CTe"><Transforms>
        <Transform Algorithm="http://www.w3.org/2000/09/xmldsig#enveloped-signature"/>
        <Transform Algorithm="http://www.w3.org/TR/2001/REC-xml-c14n-20010315"/></Transforms>
        <DigestMethod Algorithm="http://www.w3.org/2000/09/xmldsig#sha1"/><DigestValue>AAAAAAAAAAAAAAAAAAAAAAAAAAA=</DigestValue>
        </Reference></SignedInfo><SignatureValue>AAAA</SignatureValue>
        <KeyInfo><X509Data><X509Certificate>AAAA</X509Certificate></X509Data></KeyInfo></Signature>
      XML
      EVENTS = {
        "110110" => "evCCeCTe_v4.00.xsd",
        "110111" => "evCancCTe_v4.00.xsd",
        "110113" => "evEPECCTe_v4.00.xsd",
        "110160" => "evRegMultimodal_v4.00.xsd",
        "110170" => "evGTV_v4.00.xsd",
        "110180" => "evCECTe_v4.00.xsd",
        "110181" => "evCancCECTe_v4.00.xsd",
        "110190" => "evIECTe_v4.00.xsd",
        "110191" => "evCancIECTe_v4.00.xsd",
        "110300" => "evVincPgto_v4.00.xsd",
        "110301" => "evCancVincPgto_v4.00.xsd",
        "610110" => "evPrestDesacordo_v4.00.xsd",
        "610111" => "evCancPrestDesacordo_v4.00.xsd"
      }.freeze

      module_function

      def cte_issues(xml)
        document = Nokogiri::XML(xml) { |config| config.strict.nonet }
        prefixed = document.xpath("//*").find { |node| node.namespace&.prefix }
        return ["<#{prefixed.namespace.prefix}:#{prefixed.name}>: namespace prefixes are not allowed (C04, rej. 404)"] if prefixed

        root = document.root
        root.add_child(DUMMY_SIGNATURE) if root && root.at_xpath("ds:Signature", Signature::NAMESPACES).nil?
        general = Xsd.issues(document, package: PACKAGE, file: "cte_v4.00.xsd")
        general.empty? ? modal_issues(document) : general
      rescue Nokogiri::XML::SyntaxError => e
        ["not well-formed XML: #{e.message}"]
      end

      def event_issues(xml)
        document = Nokogiri::XML(xml) { |config| config.strict.nonet }
        general = Xsd.issues(document, package: PACKAGE, file: "eventoCTe_v4.00.xsd")
        return general unless general.empty?

        type = document.at_xpath("//cte:infEvento/cte:tpEvento", Signature::NAMESPACES)&.text
        file = EVENTS[type] or return ["tpEvento #{type} has no known detail schema"]
        detail = document.at_xpath("//cte:detEvento/*", Signature::NAMESPACES) or return ["detEvento is empty"]
        Xsd.issues(standalone(detail), package: PACKAGE, file: file)
      rescue Nokogiri::XML::SyntaxError => e
        ["not well-formed XML: #{e.message}"]
      end

      def modal_issues(document)
        norm = document.at_xpath("/cte:CTe/cte:infCte/cte:infCTeNorm", Signature::NAMESPACES)
        return [] unless norm

        modal = norm.at_xpath("cte:infModal/*", Signature::NAMESPACES)
        return ["infModal: the modal's group is missing"] unless modal

        file, code = Schema::MODALS[modal.name]
        return ["infModal: <#{modal.name}> is not a modal (#{Schema::MODALS.keys.join(", ")})"] unless file

        declared = document.at_xpath("/cte:CTe/cte:infCte/cte:ide/cte:modal", Signature::NAMESPACES)&.text
        return ["infModal: <#{modal.name}> is modal #{code}, but ide/modal says #{declared} (G026, rej. 580)"] unless declared == code

        Xsd.issues(standalone(modal), package: PACKAGE, file: file)
      end

      def standalone(node)
        Nokogiri::XML::Document.new.tap { |document| document.root = node.dup }
      end
    end
  end
end
