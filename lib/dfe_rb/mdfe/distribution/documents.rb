module DfeRb
  module Mdfe
    module Distribution
      module DocumentMethods
        def manifest? = kind == :manifest
        def event? = kind == :event

        def filename
          case kind
          when :manifest then "#{key}-procMDFe.xml"
          when :event then "#{key}_#{type}_#{format("%02d", sequence)}-procEventoMDFe.xml"
          else "#{nsu || Digest::SHA256.hexdigest(xml)}-unknown.xml"
          end
        end
      end

      # An authorized MDF-e with its protocol (mdfeProc). `modal` is 1 road, 2 air, 3 water,
      # 4 rail; `cargo_value` its tot/vCarga.
      ManifestDocument = Data.define(:xml, :schema, :nsu, :key, :issuer_tax_id, :issuer_name, :issued_at, :modal,
        :start_state, :end_state, :cargo_value, :protocol, :received_at, :code, :message) do
        include DocumentMethods

        def kind = :manifest
      end

      # A registered event with its protocol (procEventoMDFe): cancellation, closing, driver...
      EventDocument = Data.define(:xml, :schema, :nsu, :key, :type, :sequence, :description, :author_tax_id,
        :authority, :occurred_at, :registered_at, :protocol, :code, :message) do
        include DocumentMethods

        def kind = :event
      end

      UnknownDocument = Data.define(:xml, :schema, :nsu, :key) do
        include DocumentMethods

        def kind = :unknown
      end

      # Picks the document type from the actual root element, not from the schema attribute,
      # which comes from an untrusted response. Metadata extraction never serializes or
      # rewrites the archived XML, so its bytes are preserved.
      module Documents
        module_function

        def parse(xml, schema:, nsu:)
          root = READER.parse(xml).root
          common = {xml: xml, schema: schema, nsu: nsu}
          return UnknownDocument.new(**READER.freeze_values(common.merge(key: nil))) unless root.namespace&.href == READER.namespace

          klass, fields = case root.name
          when "mdfeProc" then [ManifestDocument, manifest(root)]
          when "procEventoMDFe" then [EventDocument, event(root)]
          else [UnknownDocument, {key: READER.text(root, "chMDFe")}]
          end
          klass.new(**READER.freeze_values(common.merge(fields)))
        end

        def key(value)
          parsed = AccessKey.parse(value.to_s)
          raise ArgumentError, "expected an MDF-e access key (model 58)" unless parsed.model == AccessKey::MODEL
          parsed.to_s.freeze
        end

        def identity(node)
          cnpj = READER.text(node, "CNPJ")
          cpf = READER.text(node, "CPF")
          raise ArgumentError, "both CNPJ and CPF present" if cnpj && cpf
          cnpj || cpf
        end

        def manifest(root)
          info = READER.element(root, "MDFe/infMDFe", required: true)
          key = key(info["Id"].to_s.delete_prefix("MDFe"))
          raise ArgumentError, "manifest/protocol keys differ" unless key == READER.text(root, "protMDFe/infProt/chMDFe", required: true)
          issuer = READER.element(info, "emit")
          value = READER.text(info, "tot/vCarga")
          raise ArgumentError, "invalid tot/vCarga" if value && !value.match?(/\A\d+(?:\.\d+)?\z/)
          {key: key, issuer_tax_id: issuer && identity(issuer), issuer_name: READER.text(info, "emit/xNome"),
           issued_at: READER.time(info, "ide/dhEmi"), modal: READER.integer(info, "ide/modal"),
           start_state: READER.text(info, "ide/UFIni"), end_state: READER.text(info, "ide/UFFim"),
           cargo_value: value && BigDecimal(value), protocol: READER.text(root, "protMDFe/infProt/nProt"),
           received_at: READER.time(root, "protMDFe/infProt/dhRecbto"), code: READER.integer(root, "protMDFe/infProt/cStat"),
           message: READER.text(root, "protMDFe/infProt/xMotivo")}
        end

        def event(root)
          info = READER.element(root, "eventoMDFe/infEvento", required: true)
          returned = READER.element(root, "retEventoMDFe/infEvento", required: true)
          type = READER.text(info, "tpEvento", required: true)
          raise ArgumentError, "event type must have six digits" unless type.match?(/\A\d{6}\z/)
          sequence = READER.integer(info, "nSeqEvento", required: true)
          raise ArgumentError, "event sequence must be 1..999" unless (1..999).cover?(sequence)
          {"chMDFe" => :text, "tpEvento" => :text, "nSeqEvento" => :integer}.each do |tag, reader|
            answered = READER.public_send(reader, returned, tag)
            raise ArgumentError, "event/return #{tag} differs" if answered && answered != READER.public_send(reader, info, tag)
          end
          {key: key(READER.text(info, "chMDFe", required: true)), type: type, sequence: sequence,
           description: info.at_xpath("doc:detEvento/*/doc:descEvento", READER.namespaces)&.text&.strip,
           author_tax_id: identity(info), authority: READER.text(info, "cOrgao"), occurred_at: READER.time(info, "dhEvento"),
           registered_at: READER.time(returned, "dhRegEvento"), protocol: READER.text(returned, "nProt"),
           code: READER.integer(returned, "cStat"), message: READER.text(returned, "xMotivo")}
        end
      end
    end
  end
end
