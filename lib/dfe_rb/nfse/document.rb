module DfeRb
  module Nfse
    # A <DPS> handed in as XML (DfeRb::Document).
    class Document < DfeRb::Document
      ROOT = "DPS"
      INFO = "infDPS"
      NAMESPACE = Nfse::NAMESPACE
      ID_PREFIX = "DPS"
      ISSUERS = {"1" => "prest", "2" => "toma", "3" => "interm"}.freeze

      # The DPS Id ("DPS" + 42 characters), or nil.
      def id
        value = info&.[]("Id").to_s
        value if value.match?(/\ADPS[0-9]{8}[0-9A-Z]{14}[0-9]{20}\z/)
      end

      def key = nil

      def environment = text("tpAmb")

      def layout_version = @root["versao"]

      # The CNPJ or CPF of whom tpEmit names: the provider, the taker or the intermediary.
      def issuer_cnpj = issuer_text("CNPJ")

      def issuer_cpf = issuer_text("CPF")

      # The X509 certificate inside the signature, or nil.
      def signer
        encoded = @root.at_xpath("ds:Signature/ds:KeyInfo/ds:X509Data/ds:X509Certificate", namespaces)&.text
        OpenSSL::X509::Certificate.new(Base64.decode64(encoded)) if encoded
      rescue OpenSSL::X509::CertificateError
        nil
      end

      # infDPS as the tag-keyed Hash the Validator reads, following `layout`'s schema.
      def to_infdps(layout) = tree(layout.dps.find("infDPS"))

      private

      def issuer_text(tag)
        group = ISSUERS[text("tpEmit").to_s] or return
        text("#{group}/#{tag}")
      end
    end

    # An NFS-e the Sefin Nacional generated (<NFSe>), read for what an issuer keeps: its
    # access key and number, the processing time and status, the values it computed, and the
    # DPS it carries.
    class Note
      attr_reader :xml

      def initialize(xml)
        @xml = xml
        @document = Nokogiri::XML(xml) { |config| config.strict.nonet }
        @plain = Nokogiri::XML(xml).tap(&:remove_namespaces!)
        raise ValidationError, ["expected an <NFSe>, got <#{@document.root&.name}>"] unless @document.root&.name == "NFSe"
      rescue Nokogiri::XML::SyntaxError => e
        raise ValidationError, ["the NFS-e is not well-formed XML: #{e.message}"]
      end

      # The 50-character access key (the Id of infNFSe less "NFS").
      def key = text("NFSe/infNFSe/@Id")&.delete_prefix("NFS")

      def number = text("NFSe/infNFSe/nNFSe")

      # 100: generated; 101: of a substitution; 102: of a judicial decision; 103: avulsa.
      def status_code = text("NFSe/infNFSe/cStat")&.to_i

      def processed_at = text("NFSe/infNFSe/dhProc")

      # Values the Sefin computed (infNFSe/valores): the ISSQN base, rate and amount, and
      # the net amount.
      def iss_base = text("NFSe/infNFSe/valores/vBC")

      def iss_rate = text("NFSe/infNFSe/valores/pAliqAplic")

      def iss_amount = text("NFSe/infNFSe/valores/vISSQN")

      def net_amount = text("NFSe/infNFSe/valores/vLiq")

      def dps_id = text("NFSe/infNFSe/DPS/infDPS/@Id")

      # The digest of the infDPS inside, computed (not read from its signature), which tells
      # whether it is the DPS sent.
      def dps_digest(digest = Signature::DIGEST)
        node = @document.at_xpath("/nfse:NFSe/nfse:infNFSe/nfse:DPS/nfse:infDPS", Signature::NAMESPACES)
        DfeRb::Signature.digest_of(node, digest) if node
      end

      # The <DPS> inside, namespaces intact.
      def dps_xml
        node = @document.at_xpath("/nfse:NFSe/nfse:infNFSe/nfse:DPS", Signature::NAMESPACES) or return
        node.dup.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
      end

      # The public consultation page the DANFSe's QR code points to (NT 008).
      def consult_url = Nfse.consult_url(key)

      def filename = "#{key}-nfse.xml"

      private

      def text(path)
        attribute = path.split("/@", 2)
        node = @plain.at_xpath("/#{attribute.first}") or return
        (attribute.size == 2) ? node[attribute.last] : node.text.strip
      end
    end

    # The public consultation of a note by its key, as the DANFSe's QR code carries it
    # (NT 008 v1.02, 2.4).
    def self.consult_url(key) = "https://www.nfse.gov.br/ConsultaPublica/?tpc=1&chave=#{key}"
  end
end
