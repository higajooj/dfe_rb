module DfeRb
  module Nfse
    NAMESPACE = "http://www.sped.fazenda.gov.br/nfse"

    # A version of the DPS layout, read from its bundled XSD package (DfeRb::Schema): the
    # tree the builder and the writer follow, and the schema documents are checked against.
    class Layout
      FILES = %w[tiposComplexos_v1.01.xsd tiposSimples_v1.01.xsd].freeze
      EVENT_FILES = %w[tiposEventos_v1.01.xsd tiposComplexos_v1.01.xsd tiposSimples_v1.01.xsd].freeze
      # libxml2 reads the ^ and $ of the production package's TSSerieDPS pattern
      # ("^0{0,4}\d{1,5}$") as characters, so it refuses every series. That message is
      # dropped for a series the pattern, anchored as intended, takes.
      LITERAL_ANCHORS = /\[facet 'pattern'\] The value '([^']*)' is not accepted by the pattern '\^0\{0,4\}\\d\{1,5\}\$'/
      SERIES = /\A0{0,4}\d{1,5}\z/

      attr_reader :name, :package, :version, :description

      def initialize(name:, package:, version:, description:)
        @name = name
        @package = package
        @version = version
        @description = description
      end

      def directory = File.join(Xsd::DIRECTORY, package)

      # The <DPS> element.
      def dps = (@dps ||= DfeRb::Schema.new(directory: directory, files: FILES, type: "TCDPS", tag: "DPS").root)

      # The <pedRegEvento> element.
      def event = (@event ||= DfeRb::Schema.new(directory: directory, files: EVENT_FILES, type: "TCPedRegEvt", tag: "pedRegEvento").root)

      # Messages for everything in a <DPS> that breaks this layout's schema. A namespace
      # prefix is refused first, as the Sefin does (E1228).
      def dps_issues(xml) = issues(xml, "DPS_v1.01.xsd")

      def event_issues(xml) = issues(xml, "pedRegEvento_v1.01.xsd")

      def nt009? = name == :nt009

      def inspect = "#<DfeRb::Nfse::Layout #{name} (#{package})>"

      private

      def issues(xml, file)
        document = Nokogiri::XML(xml) { |config| config.strict.nonet }
        prefixed = document.xpath("//*").find { |node| node.namespace&.prefix }
        return ["<#{prefixed.namespace.prefix}:#{prefixed.name}>: namespace prefixes are not allowed (E1228)"] if prefixed

        Xsd.issues(document, package: package, file: file).reject do |message|
          value = message[LITERAL_ANCHORS, 1] or next false
          value.match?(SERIES)
        end
      rescue Nokogiri::XML::SyntaxError => e
        ["not well-formed XML: #{e.message}"]
      end
    end

    # The layouts the gem writes. Both are version 1.01 and differ in shape:
    #
    # - :v1_01, the package of 09/02/2026 (nfse-esquemas_xsd-v1-01-20260209), what the
    #   Sefin Nacional validates in production;
    # - :nt009, the package of 20/10/2026 (esquemas_prod_restrita_20261020), NT 009 v1.01:
    #   the alphanumeric CNPJ, `vAjusteBC` in place of `vDedRed` and `gReeRepRes`, `finNFSe`
    #   in `infDPS`, CST and cClassTrib straight under `IBSCBS/valores/trib`, `imovel` and
    #   `bensMoveis` reshaped. Produção restrita (homologação) runs it, and production will
    #   once the CGNFS-e publishes its schedule.
    module Layouts
      ALL = {
        v1_01: Layout.new(name: :v1_01, package: "nfse_1.01", version: "1.01",
          description: "layout 1.01 of 09/02/2026, in production"),
        nt009: Layout.new(name: :nt009, package: "nfse_1.01_nt009", version: "1.01",
          description: "layout 1.01 of NT 009 (20/10/2026), in produção restrita")
      }.freeze

      # The layout each environment validates, until NT 009 reaches production.
      DEFAULTS = {Environment::PRODUCTION => :v1_01, Environment::HOMOLOGACAO => :nt009}.freeze

      module_function

      def fetch(name)
        return name if name.is_a?(Layout)

        ALL.fetch(name&.to_sym) { raise ArgumentError, "unknown NFS-e layout: #{name.inspect} (use #{ALL.keys.map(&:inspect).join(" or ")})" }
      end

      def default(environment) = ALL.fetch(DEFAULTS.fetch(Environment.normalize(environment)))
    end
  end
end
