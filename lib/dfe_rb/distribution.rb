require "base64"
require "stringio"
require "zlib"

module DfeRb
  # What the national distribution services of the DF-e have in common (NFeDistribuicaoDFe,
  # MDFeDistribuicaoDFe): strict readers, the answer with its NSU cursor and the documents
  # that come compressed in it.
  module Distribution
    # Consumo indevido: 656 at the NF-e's service, 678 at the MDF-e's.
    BLOCKED = [656, 678].freeze
    COOLDOWN = 3600

    # An unusable answer, not an ordinary SEFAZ rejection. It keeps the raw response, so a
    # consumer can diagnose corruption without discarding it or advancing its cursor.
    class InvalidResponse < TransportError
      attr_reader :response_xml, :schema, :nsu

      def initialize(message, response_xml:, schema: nil, nsu: nil)
        @response_xml = response_xml.to_s.dup.freeze
        @schema = schema&.dup&.freeze
        @nsu = nsu&.dup&.freeze
        super(message, maybe_processed: true)
      end
    end

    # The answer to a distribution request. `documents` are what the document type's own
    # parser made of each docZip.
    Result = Data.define(:query, :code, :message, :environment, :application_version,
      :responded_at, :last_nsu, :max_nsu, :documents, :request_xml, :response_xml, :retry_at) do
      def status
        case code
        when 138 then :documents
        when 137 then :empty
        when *BLOCKED then :blocked
        when 108, 109 then :unavailable
        else :rejected
        end
      end

      def success? = [137, 138].include?(code)
      def empty? = status == :empty
      def blocked? = status == :blocked
      def unavailable? = status == :unavailable
      def rejected? = !success?
      def more? = query == :dist_nsu && code == 138 && !last_nsu.nil? && !max_nsu.nil? && last_nsu < max_nsu
    end

    # Strict, namespace-aware readers of one document type's XML. They never expand entities
    # or read DTDs, external resources or schema names from a response.
    class Reader
      attr_reader :namespace, :namespaces, :response_offset

      # label: how the namespace is called in messages ("NF-e"). response_offset: the UTC
      # offset of the service's dhResp when it comes without one (the MDF-e's, in UTC).
      def initialize(namespace:, label:, response_offset: nil)
        @namespace = namespace
        @label = label
        @response_offset = response_offset
        @namespaces = {"doc" => namespace, "ds" => Signature::DS}.freeze
      end

      def parse(source, root: nil)
        doc = Nokogiri::XML(source) { |config| config.strict.nonet }
        raise ArgumentError, "XML contains a DTD" if doc.internal_subset || doc.external_subset
        raise ArgumentError, "XML has no root" unless doc.root
        if root && (doc.root.name != root || doc.root.namespace&.href != namespace)
          raise ArgumentError, "expected <#{root}> in the #{@label} namespace"
        end
        doc
      end

      def element(node, path, required: false)
        matches = node.xpath(path.split("/").map { |tag| "doc:#{tag}" }.join("/"), namespaces)
        raise ArgumentError, "multiple #{path} elements" if matches.size > 1
        raise ArgumentError, "missing #{path}" if required && matches.empty?
        matches.first
      end

      def text(node, path, required: false)
        value = element(node, path, required: required)&.text&.strip
        raise ArgumentError, "missing #{path}" if required && (value.nil? || value.empty?)
        value&.freeze
      end

      def integer(node, path, required: false)
        value = text(node, path, required: required)
        return unless value
        raise ArgumentError, "invalid #{path}: #{value.inspect}" unless value.match?(/\A\d+\z/)
        value.to_i
      end

      # offset: the UTC offset to read a timestamp that carries none in.
      def time(node, path, required: false, offset: nil)
        value = text(node, path, required: required)
        return unless value
        value += offset if offset && value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\z/)
        unless value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\z/)
          raise ArgumentError, "invalid #{path}: expected an ISO 8601 timestamp with UTC offset"
        end
        DateTime.iso8601(value) # validate the calendar date, not just Time's normalization
        Time.iso8601(value).freeze
      end

      def fragment(node)
        node.dup.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML).freeze
      end

      def nsu(value, allow_zero: true)
        supported_type = value.is_a?(Integer) || value.is_a?(String)
        unless supported_type && value.to_s.match?(/\A[0-9]{1,15}\z/)
          raise ArgumentError, "NSU must be an integer or a string of 1..15 digits"
        end
        raise ArgumentError, "NSU must be greater than zero" if !allow_zero && value.to_i.zero?
        value.to_s.rjust(15, "0").freeze
      end

      def freeze_values(values)
        values.transform_values { |value| value.is_a?(String) ? value.dup.freeze : value.freeze }
      end
    end

    # Reads <retDistDFeInt>. It decodes all or nothing, since a malformed document must not
    # look like a consumed batch.
    class Response
      # reader: the document type's Reader. documents: what turns a decoded document into a
      # value, as #parse(xml, schema:, nsu:).
      def initialize(xml, reader:, documents:, max_document_bytes:)
        @xml = xml
        @reader = reader
        @documents = documents
        @max_document_bytes = max_document_bytes
      end

      def result(query:, request_xml:, environment:, received_at:)
        root = @reader.parse(@xml, root: "retDistDFeInt").root
        code = @reader.integer(root, "cStat", required: true)
        declared = Environment.normalize(@reader.text(root, "tpAmb", required: true))
        raise ArgumentError, "response environment differs" unless declared == environment
        last_nsu = optional_nsu(root, "ultNSU")
        max_nsu = optional_nsu(root, "maxNSU")
        zips = root.xpath("doc:loteDistDFeInt/doc:docZip", @reader.namespaces)
        raise ArgumentError, "distribution returned more than 50 documents" if zips.size > 50
        raise ArgumentError, "138 without documents" if code == 138 && zips.empty?
        raise ArgumentError, "documents in a non-138 response" if code != 138 && zips.any?
        documents = zips.map { |zip| decode(zip) }.freeze
        exhausted = query == :dist_nsu && (code == 137 || (code == 138 && last_nsu && max_nsu && last_nsu == max_nsu))
        Result.new(**@reader.freeze_values(
          query: query, code: code, message: @reader.text(root, "xMotivo", required: true), environment: declared,
          application_version: @reader.text(root, "verAplic", required: true), responded_at: responded_at(root),
          last_nsu: last_nsu, max_nsu: max_nsu, documents: documents, request_xml: request_xml, response_xml: @xml,
          retry_at: (BLOCKED.include?(code) || exhausted) ? received_at + COOLDOWN : nil
        ))
      rescue Nokogiri::XML::SyntaxError, ArgumentError => e
        raise InvalidResponse.new("invalid distribution response: #{e.message}", response_xml: @xml)
      end

      private

      def responded_at(root) = @reader.time(root, "dhResp", required: true, offset: @reader.response_offset)

      def optional_nsu(root, tag)
        value = @reader.text(root, tag)
        value && @reader.nsu(value)
      end

      def decode(zip)
        schema = zip["schema"]
        nsu = zip["NSU"]
        raise ArgumentError, "docZip has no schema" if schema.nil? || schema.empty?
        raise ArgumentError, "docZip must contain only Base64 text" unless zip.element_children.empty?
        nsu = @reader.nsu(nsu) if nsu
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
        @documents.parse(xml, schema: schema, nsu: nsu)
      rescue Nokogiri::XML::SyntaxError, ArgumentError, Zlib::Error, EOFError => e
        raise InvalidResponse.new("invalid docZip: #{e.message}", response_xml: @xml, schema: schema, nsu: nsu)
      end
    end
  end
end
