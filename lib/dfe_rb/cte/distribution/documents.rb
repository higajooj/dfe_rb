module DfeRb
  module Cte
    module Distribution
      module DocumentMethods
        def waybill? = kind == :waybill
        def event? = kind == :event

        def filename
          case kind
          when :waybill then "#{key}-procCTe.xml"
          when :event then "#{key}_#{type}_#{format("%03d", sequence)}-procEventoCTe.xml"
          else "#{nsu || Digest::SHA256.hexdigest(xml)}-unknown.xml"
          end
        end
      end

      WaybillDocument = Data.define(
        :xml, :schema, :nsu, :key, :issuer_tax_id, :issuer_name, :issued_at, :modal,
        :cte_type, :service_type, :start_state, :end_state, :service_value, :cargo_value,
        :protocol, :received_at, :code, :message
      ) do
        include DocumentMethods

        def kind = :waybill
      end

      EventDocument = Data.define(
        :xml, :schema, :nsu, :key, :type, :sequence, :description, :author_tax_id,
        :authority, :occurred_at, :registered_at, :protocol, :code, :message
      ) do
        include DocumentMethods

        def kind = :event
      end

      UnknownDocument = Data.define(:xml, :schema, :nsu, :key) do
        include DocumentMethods

        def kind = :unknown
      end

      module Documents
        MODELS = [57, 64, 67].freeze

        module_function

        def parse(xml, schema:, nsu:)
          root = READER.parse(xml).root
          common = {xml: xml, schema: schema, nsu: nsu}
          return UnknownDocument.new(**READER.freeze_values(common.merge(key: nil))) unless root.namespace&.href == READER.namespace

          klass, fields = case root.name
          when "cteProc" then [WaybillDocument, waybill(root)]
          when "procEventoCTe" then [EventDocument, event(root)]
          else [UnknownDocument, {key: READER.text(root, "protCTe/infProt/chCTe")}]
          end
          klass.new(**READER.freeze_values(common.merge(fields)))
        end

        def key(value, models: MODELS)
          parsed = DfeRb::AccessKey.parse(value.to_s)
          raise ArgumentError, "expected a CT-e access key (models #{models.join(", ")})" unless models.include?(parsed.model)

          parsed.to_s.freeze
        end

        def identity(node)
          cnpj = READER.text(node, "CNPJ")
          cpf = READER.text(node, "CPF")
          raise ArgumentError, "both CNPJ and CPF present" if cnpj && cpf

          cnpj || cpf
        end

        def decimal(node, path)
          value = READER.text(node, path)
          return unless value
          raise ArgumentError, "invalid #{path}" unless value.match?(/\A\d+(?:\.\d+)?\z/)

          BigDecimal(value)
        end

        def waybill(root)
          info = READER.element(root, "CTe/infCte", required: true)
          doc_key = key(info["Id"].to_s.delete_prefix("CTe"), models: [AccessKey::MODEL])
          raise ArgumentError, "waybill/protocol keys differ" unless doc_key == READER.text(root, "protCTe/infProt/chCTe", required: true)

          issuer = READER.element(info, "emit")
          {
            key: doc_key,
            issuer_tax_id: issuer && identity(issuer),
            issuer_name: READER.text(info, "emit/xNome"),
            issued_at: READER.time(info, "ide/dhEmi"),
            modal: READER.text(info, "ide/modal"),
            cte_type: READER.integer(info, "ide/tpCTe"),
            service_type: READER.integer(info, "ide/tpServ"),
            start_state: READER.text(info, "ide/UFIni"),
            end_state: READER.text(info, "ide/UFFim"),
            service_value: decimal(info, "vPrest/vTPrest"),
            cargo_value: decimal(info, "infCTeNorm/infCarga/vCarga"),
            protocol: READER.text(root, "protCTe/infProt/nProt"),
            received_at: READER.time(root, "protCTe/infProt/dhRecbto"),
            code: READER.integer(root, "protCTe/infProt/cStat"),
            message: READER.text(root, "protCTe/infProt/xMotivo")
          }
        end

        def event(root)
          info = READER.element(root, "eventoCTe/infEvento", required: true)
          returned = READER.element(root, "retEventoCTe/infEvento", required: true)
          type = READER.text(info, "tpEvento", required: true)
          raise ArgumentError, "event type must have six digits" unless type.match?(/\A\d{6}\z/)

          sequence = READER.integer(info, "nSeqEvento", required: true)
          raise ArgumentError, "event sequence must be 1..999" unless (1..999).cover?(sequence)

          {"chCTe" => :text, "tpEvento" => :text, "nSeqEvento" => :integer}.each do |tag, reader|
            answered = READER.public_send(reader, returned, tag)
            raise ArgumentError, "event/return #{tag} differs" if answered && answered != READER.public_send(reader, info, tag)
          end
          {
            key: key(READER.text(info, "chCTe", required: true)),
            type: type,
            sequence: sequence,
            description: info.at_xpath("doc:detEvento/*/doc:descEvento", READER.namespaces)&.text&.strip,
            author_tax_id: identity(info),
            authority: READER.text(info, "cOrgao"),
            occurred_at: READER.time(info, "dhEvento"),
            registered_at: READER.time(returned, "dhRegEvento"),
            protocol: READER.text(returned, "nProt"),
            code: READER.integer(returned, "cStat"),
            message: READER.text(returned, "xMotivo")
          }
        end
      end
    end
  end
end
