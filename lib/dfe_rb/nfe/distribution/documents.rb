module DfeRb
  module Nfe
    module Distribution
      module DocumentMethods
        def summary? = [:invoice_summary, :event_summary].include?(kind)
        def invoice? = [:invoice, :invoice_summary].include?(kind)
        def event? = [:event, :event_summary].include?(kind)

        def filename
          case kind
          when :invoice then "#{key}-procNFe.xml"
          when :invoice_summary then "#{key}-resNFe.xml"
          when :event, :event_summary
            suffix = (kind == :event) ? "procEventoNFe" : "resEvento"
            "#{key}_#{type}_#{format("%02d", sequence)}-#{suffix}.xml"
          else "#{nsu || Digest::SHA256.hexdigest(xml)}-unknown.xml"
          end
        end
      end

      InvoiceSummary = Data.define(:xml, :schema, :nsu, :key, :issuer_tax_id, :issuer_name, :state_registration,
        :issued_at, :direction, :total, :digest_value, :received_at, :protocol, :situation_code) do
        include DocumentMethods

        def kind = :invoice_summary
        def status = {1 => :authorized, 2 => :denied, 3 => :canceled}.fetch(situation_code, :unknown)
      end

      InvoiceDocument = Data.define(:xml, :schema, :nsu, :key, :issuer_tax_id, :issuer_name, :recipient_tax_id,
        :issued_at, :total, :protocol, :received_at, :code, :message) do
        include DocumentMethods

        def kind = :invoice
      end

      EventSummary = Data.define(:xml, :schema, :nsu, :key, :type, :sequence, :description, :author_tax_id,
        :authority, :occurred_at, :registered_at, :protocol) do
        include DocumentMethods

        def kind = :event_summary
      end

      EventDocument = Data.define(:xml, :schema, :nsu, :key, :type, :sequence, :description, :author_tax_id,
        :authority, :occurred_at, :registered_at, :protocol, :code, :message) do
        include DocumentMethods

        def kind = :event
      end

      UnknownDocument = Data.define(:xml, :schema, :nsu, :key) do
        include DocumentMethods

        def kind = :unknown
      end

      # Select by the actual root, not by the untrusted schema attribute. Preserve bytes;
      # metadata extraction never serializes or rewrites the archived XML.
      module Documents
        module_function

        def parse(xml, schema:, nsu:)
          root = Xml.parse(xml).root
          common = {xml: xml, schema: schema, nsu: nsu}
          return UnknownDocument.new(**Xml.freeze_values(common.merge(key: nil))) unless root.namespace&.href == Signature::NFE

          klass, fields = case root.name
          when "resNFe" then [InvoiceSummary, invoice_summary(root)]
          when "nfeProc", "procNFe" then [InvoiceDocument, invoice(root)]
          when "resEvento" then [EventSummary, event_summary(root)]
          when "procEventoNFe" then [EventDocument, event(root)]
          else [UnknownDocument, {key: Xml.text(root, "chNFe")}]
          end
          klass.new(**Xml.freeze_values(common.merge(fields)))
        end

        def identity(node)
          cnpj = Xml.text(node, "CNPJ")
          cpf = Xml.text(node, "CPF")
          raise ArgumentError, "both CNPJ and CPF present" if cnpj && cpf
          cnpj || cpf
        end

        def decimal(node, path)
          value = Xml.text(node, path, required: true)
          raise ArgumentError, "invalid #{path}" unless value.match?(/\A\d+(?:\.\d+)?\z/)
          BigDecimal(value)
        end

        def invoice_summary(root)
          {key: Xml.key(Xml.text(root, "chNFe", required: true)), issuer_tax_id: identity(root),
           issuer_name: Xml.text(root, "xNome"), state_registration: Xml.text(root, "IE"),
           issued_at: Xml.time(root, "dhEmi"), direction: Xml.integer(root, "tpNF"), total: decimal(root, "vNF"),
           digest_value: Xml.text(root, "digVal"), received_at: Xml.time(root, "dhRecbto"),
           protocol: Xml.text(root, "nProt"), situation_code: Xml.integer(root, "cSitNFe")}
        end

        def invoice(root)
          info = Xml.element(root, "NFe/infNFe", required: true)
          key = Xml.key(info["Id"].to_s.delete_prefix("NFe"))
          protocol_key = Xml.text(root, "protNFe/infProt/chNFe", required: true)
          raise ArgumentError, "invoice/protocol keys differ" unless key == protocol_key
          issuer = info.at_xpath("nfe:emit", Xml::NS)
          recipient = info.at_xpath("nfe:dest", Xml::NS)
          {key: key, issuer_tax_id: issuer && identity(issuer), issuer_name: Xml.text(info, "emit/xNome"),
           recipient_tax_id: recipient && identity(recipient), issued_at: issued_at(info),
           total: decimal(info, "total/ICMSTot/vNF"), protocol: Xml.text(root, "protNFe/infProt/nProt"),
           received_at: Xml.time(root, "protNFe/infProt/dhRecbto"), code: Xml.integer(root, "protNFe/infProt/cStat"),
           message: Xml.text(root, "protNFe/infProt/xMotivo")}
        end

        def issued_at(info)
          timestamp = Xml.time(info, "ide/dhEmi")
          return timestamp if timestamp
          value = Xml.text(info, "ide/dEmi")
          return unless value
          date = Date.iso8601(value)
          Time.utc(date.year, date.month, date.day).freeze
        end

        def event_summary(root)
          {key: Xml.key(Xml.text(root, "chNFe", required: true)), type: event_type(root),
           sequence: event_sequence(root), description: Xml.text(root, "xEvento"),
           author_tax_id: identity(root), authority: Xml.text(root, "cOrgao"), occurred_at: Xml.time(root, "dhEvento"),
           registered_at: Xml.time(root, "dhRecbto"), protocol: Xml.text(root, "nProt")}
        end

        def event(root)
          info = Xml.element(root, "evento/infEvento", required: true)
          returned = Xml.element(root, "retEvento/infEvento", required: true)
          fields = event_summary_fields(info)
          %w[chNFe tpEvento].each do |tag|
            unless Xml.text(info, tag, required: true) == Xml.text(returned, tag, required: true)
              raise ArgumentError, "event/return #{tag} differs"
            end
          end
          unless fields[:sequence] == event_sequence(returned)
            raise ArgumentError, "event/return nSeqEvento differs"
          end
          fields.merge(registered_at: Xml.time(returned, "dhRegEvento"), protocol: Xml.text(returned, "nProt"),
            code: Xml.integer(returned, "cStat"), message: Xml.text(returned, "xMotivo"))
        end

        def event_type(node)
          value = Xml.text(node, "tpEvento", required: true)
          raise ArgumentError, "event type must have six digits" unless value.match?(/\A\d{6}\z/)
          value
        end

        def event_sequence(node)
          value = Xml.integer(node, "nSeqEvento", required: true)
          raise ArgumentError, "event sequence must be 1..99" unless (1..99).cover?(value)
          value
        end

        def event_summary_fields(info)
          {key: Xml.key(Xml.text(info, "chNFe", required: true)), type: event_type(info),
           sequence: event_sequence(info), description: Xml.text(info, "detEvento/descEvento"),
           author_tax_id: identity(info), authority: Xml.text(info, "cOrgao"), occurred_at: Xml.time(info, "dhEvento")}
        end
      end
    end
  end
end
