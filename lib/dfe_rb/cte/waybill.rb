module DfeRb
  module Cte
    class Waybill
      SIGNED_QR_EMISSION_TYPES = %w[2 4].freeze

      attr_reader :environment

      def initialize(attributes = nil, environment: Environment::HOMOLOGACAO, clock: Time, certificate: nil,
        technical_contact: nil, qr_code_url: nil, **fields)
        @environment = Environment.normalize(environment)
        @clock = clock
        @certificate = certificate
        @qr_code_url = qr_code_url
        @infcte = {}
        @memo = Resolver::Memo.new
        contact = (technical_contact || {}).transform_keys(&:to_sym)
        @csrt = contact.delete(:csrt)
        scope.technical_contact(contact) unless contact.empty?
        given = (attributes || {}).merge(fields)
        scope.__assign(given) unless given.empty?
        yield scope if block_given?
      end

      def scope = Scope.new(Schema.cte.find("infCte"), @infcte)

      def resolved = resolve.first

      def key
        tree, problems = resolve
        id = tree["@Id"] or raise ValidationError,
          problems.empty? ? ["cannot build the access key yet: fill in the issuer, series and number"] : problems
        AccessKey.parse(id.delete_prefix("CTe"))
      end

      def qr_code = qr_code_of(resolved)

      def to_xml(strict: true)
        xml, found = render(strict: strict)
        raise ValidationError, found unless found.empty?

        xml
      end

      def issues(strict: true) = render(strict: strict).last

      def valid?(strict: true) = issues(strict: strict).empty?

      def validate!(strict: true)
        found = issues(strict: strict)
        raise ValidationError, found unless found.empty?

        self
      end

      private

      def resolve
        resolver = Resolver.new(environment: environment, memo: @memo, clock: @clock, csrt: @csrt)
        tree = resolver.call(@infcte)
        [tree, resolver.issues]
      end

      def signed_qr?(tree) = SIGNED_QR_EMISSION_TYPES.include?(tree.dig("ide", "tpEmis").to_s)

      def qr_code_of(tree)
        id = tree["@Id"] or return
        state = tree.dig("emit", "enderEmit", "UF")
        return unless state && DfeRb::States::CODES.key?(state)
        return if signed_qr?(tree) && @certificate.nil?

        QrCode.url(
          key: id.delete_prefix("CTe"), state: state, environment: tree.dig("ide", "tpAmb"),
          certificate: (@certificate if signed_qr?(tree)), base_url: @qr_code_url
        )
      end

      def render(strict:)
        tree, problems = resolve
        url = qr_code_of(tree)
        if url.nil? && tree["@Id"] && signed_qr?(tree)
          problems += ["a waybill issued in offline or EPEC contingency needs the certificate to sign its QR code: " \
            "build it with client.build_waybill or pass certificate: (MOC 9.2.2)"]
        end
        writer = XmlWriter.new
        xml = writer.write({"infCte" => tree, "infCTeSupl" => ({"qrCodCTe" => url} if url)}.compact)
        found = problems + writer.issues
        found.concat(Schemas.cte_issues(xml)) if found.empty?
        found.concat(Validator.new(tree, qr_code: url, clock: @clock, csrt: @csrt, qr_code_base_url: @qr_code_url).issues) if strict
        [xml, found]
      end
    end
  end
end
