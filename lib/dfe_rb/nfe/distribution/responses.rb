module DfeRb
  module Nfe
    module Distribution
      # All-or-nothing decoding. A malformed document must not look like a consumed batch.
      class DistributionResponse
        def initialize(xml, max_document_bytes:)
          @xml = xml
          @max_document_bytes = max_document_bytes
        end

        def result(query:, request_xml:, environment:, received_at:)
          root = Xml.parse(@xml, root: "retDistDFeInt").root
          code = Xml.integer(root, "cStat", required: true)
          declared = Environment.normalize(Xml.text(root, "tpAmb", required: true))
          raise ArgumentError, "response environment differs" unless declared == environment
          last_nsu = optional_nsu(root, "ultNSU")
          max_nsu = optional_nsu(root, "maxNSU")
          zips = root.xpath("nfe:loteDistDFeInt/nfe:docZip", Xml::NS)
          raise ArgumentError, "distribution returned more than 50 documents" if zips.size > 50
          raise ArgumentError, "138 without documents" if code == 138 && zips.empty?
          raise ArgumentError, "documents in a non-138 response" if code != 138 && zips.any?
          documents = zips.map { |zip| decode(zip) }.freeze
          exhausted = query == :dist_nsu && (code == 137 || (code == 138 && last_nsu && max_nsu && last_nsu == max_nsu))
          DistributionResult.new(**Xml.freeze_values(
            query: query, code: code, message: Xml.text(root, "xMotivo", required: true), environment: declared,
            application_version: Xml.text(root, "verAplic", required: true), responded_at: Xml.time(root, "dhResp", required: true),
            last_nsu: last_nsu, max_nsu: max_nsu, documents: documents, request_xml: request_xml, response_xml: @xml,
            retry_at: (code == 656 || exhausted) ? received_at + 3600 : nil
          ))
        rescue Nokogiri::XML::SyntaxError, ArgumentError => e
          raise InvalidResponse.new("invalid distribution response: #{e.message}", response_xml: @xml)
        end

        private

        def optional_nsu(root, tag)
          value = Xml.text(root, tag)
          value && Xml.nsu(value)
        end

        def decode(zip)
          schema = zip["schema"]
          nsu = zip["NSU"]
          raise ArgumentError, "docZip has no schema" if schema.nil? || schema.empty?
          raise ArgumentError, "docZip must contain only Base64 text" unless zip.element_children.empty?
          nsu = Xml.nsu(nsu) if nsu
          compressed = Base64.strict_decode64(zip.text.delete(" \t\r\n"))
          xml = Zlib::GzipReader.wrap(StringIO.new(compressed)) do |gzip|
            output = +""
            while (chunk = gzip.read([16_384, @max_document_bytes + 1 - output.bytesize].min)) && !chunk.empty?
              output << chunk
              raise ArgumentError, "document exceeds #{@max_document_bytes} decompressed bytes" if output.bytesize > @max_document_bytes
            end
            raise ArgumentError, "trailing data after gzip document" unless gzip.unused.nil? || gzip.unused.empty?
            output.force_encoding(Encoding::UTF_8)
          end
          Documents.parse(xml, schema: schema, nsu: nsu)
        rescue Nokogiri::XML::SyntaxError, ArgumentError, Zlib::Error, EOFError => e
          raise InvalidResponse.new("invalid docZip: #{e.message}", response_xml: @xml, schema: schema, nsu: nsu)
        end
      end

      class ManifestationResponse
        def initialize(xml)
          @xml = xml
        end

        def results(events:, request_xml:, environment:)
          root = Xml.parse(@xml, root: "retEnvEvento").root
          code = Xml.integer(root, "cStat", required: true)
          message = Xml.text(root, "xMotivo", required: true)
          declared = Environment.normalize(Xml.text(root, "tpAmb", required: true))
          raise ArgumentError, "response environment differs" unless declared == environment
          returned = root.xpath("nfe:retEvento", Xml::NS)
          if code != 128
            raise ArgumentError, "event answers in a rejected lot" if returned.any?
            return events.map { |event| result(event, code, message, nil, request_xml) }
          end
          answers = returned.to_h do |node|
            info = Xml.element(node, "infEvento", required: true)
            identity = [Xml.key(Xml.text(info, "chNFe", required: true)), Xml.text(info, "tpEvento", required: true),
              Xml.integer(info, "nSeqEvento", required: true)]
            [identity, node]
          end
          unless answers.size == returned.size && answers.keys.sort == events.map(&:identity).sort
            raise ArgumentError, "missing, duplicate or unexpected event answers"
          end
          events.map do |event|
            node = answers.fetch(event.identity)
            info = Xml.element(node, "infEvento", required: true)
            if Environment.normalize(Xml.text(info, "tpAmb", required: true)) != environment
              raise ArgumentError, "event answer environment differs"
            end
            result(event, Xml.integer(info, "cStat", required: true), Xml.text(info, "xMotivo", required: true), node, request_xml)
          end
        rescue Nokogiri::XML::SyntaxError, ArgumentError => e
          raise InvalidResponse.new("invalid manifestation response: #{e.message}", response_xml: @xml)
        end

        private

        def result(event, code, message, returned, request_xml)
          info = returned&.at_xpath("nfe:infEvento", Xml::NS)
          protocol = info && Xml.text(info, "nProt")
          registered_at = info && Xml.time(info, "dhRegEvento")
          if [135, 136].include?(code) && (protocol.nil? || protocol.empty? || registered_at.nil?)
            raise ArgumentError, "registered event lacks protocol or registration time"
          end
          ManifestationResult.new(**Xml.freeze_values(key: event.key, type: event.type, sequence: event.sequence,
            code: code, message: message, protocol: protocol, registered_at: registered_at,
            event_xml: event.xml, return_xml: returned && Xml.fragment(returned),
            request_xml: request_xml, response_xml: @xml))
        end
      end
    end
  end
end
