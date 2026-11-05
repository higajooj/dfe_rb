require "base64"
require "openssl"

module DfeRb
  module Nfe
    # An <NFe> handed in as XML (DfeRb::Document).
    class Document < DfeRb::Document
      ROOT = "NFe"
      INFO = "infNFe"
      NAMESPACE = Signature::NFE
      ID_PREFIX = "NFe"

      # infNFe as the tag-keyed Hash the Validator reads, following the schema.
      def to_infnfe = tree(Schema.nfe.find("infNFe"))

      # ide/mod: "55", or "65" for an NFC-e.
      def model = text("ide/mod")

      # infNFeSupl ({"qrCode" => ..., "urlChave" => ...}), which an NFC-e carries; nil without it.
      def supplement
        node = @root.at_xpath("doc:infNFeSupl", namespaces) or return

        %w[qrCode urlChave].to_h { |tag| [tag, node.at_xpath("doc:#{tag}", namespaces)&.text] }
      end

      # The OpenSSL certificate in the note's signature, or nil when unsigned.
      def signer
        encoded = @root.at_xpath("ds:Signature/ds:KeyInfo/ds:X509Data/ds:X509Certificate", namespaces) or return

        OpenSSL::X509::Certificate.new(Base64.decode64(encoded.text))
      rescue OpenSSL::X509::CertificateError
        nil
      end

      # A copy with `infNFeSupl` ({"qrCode" => ..., "urlChave" => ...}) after infNFe. Only
      # for an unsigned note, since the signature follows infNFeSupl.
      def with_supplement(supplement)
        raise ArgumentError, "a signed note can't take infNFeSupl" if signed?

        document = @root.document.dup
        root = document.root
        info = root.at_xpath("doc:infNFe", namespaces)
        supl = info.add_next_sibling(Nokogiri::XML::Node.new("infNFeSupl", document))
        supl.namespace = info.namespace
        %w[qrCode urlChave].each do |tag|
          child = supl.add_child(Nokogiri::XML::Node.new(tag, document))
          child.namespace = info.namespace
          child.content = supplement.fetch(tag)
        end
        self.class.new(root.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML))
      end
    end
  end
end
