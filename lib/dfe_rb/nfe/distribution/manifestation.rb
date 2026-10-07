module DfeRb
  module Nfe
    module Distribution
      module Manifestations
        TYPES = {
          awareness: ["210210", "Ciencia da Operacao"],
          confirmation: ["210200", "Confirmacao da Operacao"],
          unknown_operation: ["210220", "Desconhecimento da Operacao"],
          not_performed: ["210240", "Operacao nao Realizada"]
        }.freeze

        module_function

        def definition(type)
          TYPES.fetch(type) { raise ArgumentError, "unknown manifestation: #{type.inspect} (use #{TYPES.keys.join(", ")})" }
        end

        def validate_details!(type:, sequence:, reason:)
          code, description = definition(type)
          allowed = (type == :awareness) ? 1..1 : 1..2
          unless sequence.is_a?(Integer) && allowed.cover?(sequence)
            raise ValidationError, ["sequence must be #{allowed} for #{type}"]
          end
          if type == :not_performed
            unless reason.is_a?(String) && reason.valid_encoding? && !reason.include?("\0") && (15..255).cover?(reason.strip.length)
              raise ValidationError, ["reason must be valid text with 15..255 characters for not_performed"]
            end
          elsif !reason.nil?
            raise ValidationError, ["reason is only allowed for not_performed"]
          end
          [code, description]
        end

        def build(key:, type:, sequence:, reason:, tax_id:, environment:, at:)
          code, description = validate_details!(type: type, sequence: sequence, reason: reason)
          raise ArgumentError, "at must be a Time" unless at.is_a?(Time)
          tag = (TaxId.type(tax_id) == :cnpj) ? "CNPJ" : "CPF"
          id = "ID#{code}#{key}#{format("%02d", sequence)}"
          detail = "<descEvento>#{description}</descEvento>"
          detail += "<xJust>#{Requests.escape(reason.strip)}</xJust>" if reason
          %(<evento xmlns="#{Signature::NFE}" versao="1.00"><infEvento Id="#{id}"><cOrgao>91</cOrgao>) +
            %(<tpAmb>#{Environment.code(environment)}</tpAmb><#{tag}>#{tax_id}</#{tag}><chNFe>#{key}</chNFe>) +
            %(<dhEvento>#{at.strftime("%Y-%m-%dT%H:%M:%S%:z")}</dhEvento><tpEvento>#{code}</tpEvento>) +
            %(<nSeqEvento>#{sequence}</nSeqEvento><verEvento>1.00</verEvento><detEvento versao="1.00">#{detail}</detEvento>) +
            %(</infEvento></evento>)
        end
      end

      # A signed event that can be stored and restored. Its metadata is always read from the
      # XML, never taken from a caller-provided key or type. Restoring it verifies the
      # structure. Submitting it also verifies identity and signature. Persist `xml` before
      # sending a request that may reach SEFAZ.
      class SignedManifestation
        attr_reader :xml, :key, :type, :sequence, :tax_id, :environment, :occurred_at, :id

        def initialize(xml:)
          source = xml.to_s.dup.force_encoding(Encoding::UTF_8)
          document = Xml.parse(source, root: "evento")
          @xml = source.sub(Document::DECLARATION, "").rstrip.freeze
          root = document.root
          info = Xml.element(root, "infEvento", required: true)
          @key = Xml.key(Xml.text(info, "chNFe", required: true))
          @type = Xml.text(info, "tpEvento", required: true)
          symbol = Manifestations::TYPES.find { |_, (code, _)| code == @type }&.first
          raise ArgumentError, "not a recipient manifestation: #{@type}" unless symbol
          @sequence = Xml.integer(info, "nSeqEvento", required: true)
          reason = Xml.text(info, "detEvento/xJust")
          _, description = Manifestations.validate_details!(type: symbol, sequence: @sequence, reason: reason)
          raise ArgumentError, "manifestation description differs" unless Xml.text(info, "detEvento/descEvento") == description
          raise ArgumentError, "manifestation must use cOrgao 91" unless Xml.text(info, "cOrgao") == "91"
          @tax_id = Documents.identity(info)
          raise ArgumentError, "invalid manifestation author" unless TaxId.type(@tax_id)
          @environment = Environment.normalize(Xml.text(info, "tpAmb", required: true))
          @occurred_at = Xml.time(info, "dhEvento", required: true)
          @id = info["Id"]&.dup&.freeze
          expected = "ID#{@type}#{@key}#{format("%02d", @sequence)}"
          raise ArgumentError, "manifestation Id differs from its identity" unless @id == expected
          ids = document.xpath("//@Id").map(&:value)
          raise ArgumentError, "duplicate XML Ids" unless ids.uniq.size == ids.size
          signature = root.xpath("ds:Signature", Xml::NS)
          reference = signature.first&.xpath("ds:SignedInfo/ds:Reference", Xml::NS)
          unless signature.size == 1 && reference&.size == 1 && reference.first["URI"] == "##{@id}"
            raise ArgumentError, "signature must reference this manifestation once"
          end
          transforms = reference.first.xpath("ds:Transforms/ds:Transform", Xml::NS)
          expected_transforms = ["#{Signature::DS}enveloped-signature", Signature::C14N]
          unless transforms.map { |node| node["Algorithm"] } == expected_transforms && transforms.all? { |node| node.element_children.empty? }
            raise ArgumentError, "unexpected signature transforms"
          end
          detail = info.at_xpath("nfe:detEvento", Xml::NS)
          Schemas.validate!(Xml.fragment(detail), package: "Evento_ManifestaDest_PL_v1.01", file: "e#{@type}_v1.00.xsd")
          Schemas.validate!(Requests.event_batch([@xml], lot_id: "1"), package: "event_1.00", file: "envEvento_v1.00.xsd")
          freeze
        rescue Nokogiri::XML::SyntaxError, ArgumentError => e
          raise ValidationError, ["invalid signed manifestation: #{e.message}"]
        end

        def verify!
          problem = Signature.verify(xml)
          raise ValidationError, ["manifestation signature does not verify: #{problem}"] unless problem == true
          encoded = Xml.parse(xml).at_xpath("/nfe:evento/ds:Signature/ds:KeyInfo/ds:X509Data/ds:X509Certificate", Xml::NS).text
          signer = OpenSSL::X509::Certificate.new(Base64.strict_decode64(encoded.delete(" \t\r\n")))
          signer_id = Certificate.tax_id_of(signer)
          matches = if TaxId.type(tax_id) == :cnpj
            TaxId.type(signer_id) == :cnpj && signer_id[0, 8] == tax_id[0, 8]
          else
            signer_id == tax_id
          end
          raise ValidationError, ["signing certificate does not match the manifestation author"] unless matches
          unless occurred_at.between?(signer.not_before, signer.not_after)
            raise ValidationError, ["signing certificate was not valid at the event time"]
          end
          self
        rescue OpenSSL::OpenSSLError, ArgumentError, NoMethodError => e
          raise ValidationError, ["invalid manifestation signature: #{e.message}"]
        end

        def identity = [key, type, sequence]
        def filename = "#{key}_#{type}_#{format("%02d", sequence)}-evento.xml"
        def to_s = xml
      end
    end
  end
end
