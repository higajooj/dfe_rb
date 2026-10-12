module DfeRb
  module Nfe
    module Distribution
      # Reads <retDistDFeInt> into a DistributionResult with NF-e documents
      # (DfeRb::Distribution::Response).
      class DistributionResponse < DfeRb::Distribution::Response
        def initialize(xml, max_document_bytes:)
          super(xml, reader: Xml::READER, documents: Documents, max_document_bytes: max_document_bytes)
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
