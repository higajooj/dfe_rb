require "bigdecimal"

module DfeRb
  module Nfse
    class Document < DfeRb::Document
      ROOT = "DPS"
      INFO = "infDPS"
      NAMESPACE = Nfse::NAMESPACE
      ID_PREFIX = "DPS"
      ISSUERS = {"1" => "prest", "2" => "toma", "3" => "interm"}.freeze

      def id
        value = info&.[]("Id").to_s
        value if value.match?(/\ADPS[0-9]{8}[0-9A-Z]{14}[0-9]{20}\z/)
      end

      def key = nil

      def environment = text("tpAmb")

      def layout_version = @root["versao"]

      def issuer_cnpj = issuer_text("CNPJ")

      def issuer_cpf = issuer_text("CPF")

      def signer
        encoded = @root.at_xpath("ds:Signature/ds:KeyInfo/ds:X509Data/ds:X509Certificate", namespaces)&.text
        OpenSSL::X509::Certificate.new(Base64.decode64(encoded)) if encoded
      rescue OpenSSL::X509::CertificateError
        nil
      end

      def to_infdps(layout) = tree(layout.dps.find("infDPS"))

      private

      def issuer_text(tag)
        group = ISSUERS[text("tpEmit").to_s] or return
        text("#{group}/#{tag}")
      end
    end

    # A party of a note: the provider (emit), the taker or the intermediary. `tax_id` is the
    # CNPJ or CPF, nil for a foreigner known by `nif`.
    Party = Data.define(:tax_id, :nif, :name, :municipal_registration, :city_code, :email)

    # The service a note is for (serv/cServ, serv/locPrest) and the national code's name
    # the Sefin wrote (xTribNac).
    Service = Data.define(:national_code, :municipal_code, :description, :nbs, :city_code, :national_name)

    # What the taker (or the intermediary) withheld of each tax, as BigDecimal, zero when
    # nothing: the ISSQN, the social security (vRetCP, INSS), the IRRF, the CSLL, and the PIS
    # and the COFINS when tpRetPisCofins says they were withheld.
    Withholdings = Data.define(:iss, :social_security, :irrf, :csll, :pis, :cofins) do
      def total = to_h.values.sum

      def any? = total.positive?
    end

    # An NFS-e the Sefin Nacional generated (<NFSe>), read for what its issuer and its taker
    # keep: its access key and number, the processing time and status, its parties, service
    # and values, what was withheld, and the DPS it carries.
    class Note
      # tpRetISSQN.
      ISS_WITHHOLDING = {"1" => :none, "2" => :taker, "3" => :intermediary}.freeze
      # The tpRetPisCofins codes under which each tax was withheld (Anexo I; the CSLL's own
      # amount, vRetCSLL, is given apart).
      PIS_WITHHELD = %w[1 3 4 5 9].freeze
      COFINS_WITHHELD = %w[1 3 4 6 7].freeze
      DPS = "NFSe/infNFSe/DPS/infDPS"

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

      # Whether the Sefin's signature over infNFSe checks out (its digest and value, with
      # the certificate it carries): true, or the reason it doesn't. A note that comes as
      # a file, from anyone, is taken only so.
      def signature_problem
        return "the note has no access key" unless key

        result = DfeRb::Signature.verify(xml, digests: %i[sha256 sha1], of: "NFS#{key}")
        (result == true) ? nil : result
      rescue ArgumentError, NoMethodError, OpenSSL::OpenSSLError => e
        e.message
      end

      def signed? = signature_problem.nil?

      # The provider, as the Sefin wrote it from the registers (emit).
      def provider
        party("NFSe/infNFSe/emit", city: "enderNac/cMun")
      end

      # The taker named in the DPS, or nil.
      def taker = party("#{DPS}/toma")

      def intermediary = party("#{DPS}/interm")

      # When the DPS was issued (dhEmi) and the competence it declares (dCompet).
      def issued_at = time(text("#{DPS}/dhEmi"))

      def competence_on = date(text("#{DPS}/dCompet"))

      def series = text("#{DPS}/serie")

      def dps_number = text("#{DPS}/nDPS")

      # 1: production, 2: produção restrita (the DPS's tpAmb).
      def environment = text("#{DPS}/tpAmb")

      def service
        Service.new(
          national_code: text("#{DPS}/serv/cServ/cTribNac"), municipal_code: text("#{DPS}/serv/cServ/cTribMun"),
          description: text("#{DPS}/serv/cServ/xDescServ"), nbs: text("#{DPS}/serv/cServ/cNBS"),
          city_code: text("#{DPS}/serv/locPrest/cLocPrestacao"), national_name: text("NFSe/infNFSe/xTribNac")
        )
      end

      # Where the ISSQN is due (cLocIncid), when it is.
      def incidence_city_code = text("NFSe/infNFSe/cLocIncid")

      # The service's value and its discounts, as BigDecimal (zero when absent).
      def service_amount = decimal("#{DPS}/valores/vServPrest/vServ")

      def unconditional_discount = decimal("#{DPS}/valores/vDescCondIncond/vDescIncond")

      def conditional_discount = decimal("#{DPS}/valores/vDescCondIncond/vDescCond")

      # Who withholds the ISSQN: :none, :taker or :intermediary.
      def iss_withholding = ISS_WITHHOLDING[text("#{DPS}/valores/trib/tribMun/tpRetISSQN")]

      def iss_withheld? = %i[taker intermediary].include?(iss_withholding)

      def withheld
        federal = "#{DPS}/valores/trib/tribFed"
        pis_cofins = text("#{federal}/piscofins/tpRetPisCofins")
        Withholdings.new(
          iss: iss_withheld? ? decimal("NFSe/infNFSe/valores/vISSQN") : BigDecimal(0),
          social_security: decimal("#{federal}/vRetCP"), irrf: decimal("#{federal}/vRetIRRF"), csll: decimal("#{federal}/vRetCSLL"),
          pis: PIS_WITHHELD.include?(pis_cofins) ? decimal("#{federal}/piscofins/vPis") : BigDecimal(0),
          cofins: COFINS_WITHHELD.include?(pis_cofins) ? decimal("#{federal}/piscofins/vCofins") : BigDecimal(0)
        )
      end

      # vTotalRet as the Sefin computed it, else the sum of what was withheld.
      def total_withheld
        stated = text("NFSe/infNFSe/valores/vTotalRet")
        (stated.nil? || stated.empty?) ? withheld.total : BigDecimal(stated)
      end

      private

      def party(path, city: "end/endNac/cMun")
        return unless @plain.at_xpath("/#{path}")

        Party.new(tax_id: text("#{path}/CNPJ") || text("#{path}/CPF"), nif: text("#{path}/NIF"), name: text("#{path}/xNome"),
          municipal_registration: text("#{path}/IM"), city_code: text("#{path}/#{city}"), email: text("#{path}/email"))
      end

      def decimal(path)
        value = text(path)
        (value.nil? || value.empty?) ? BigDecimal(0) : BigDecimal(value)
      end

      def time(value) = value && Time.iso8601(value)

      def date(value) = value && Date.iso8601(value)

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
