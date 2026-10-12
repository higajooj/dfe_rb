module DfeRb
  module Mdfe
    # An MDF-e being put together. Fill it through the builder block, a hash, or both:
    #
    #   manifest = DfeRb::Mdfe::Manifest.new(environment: :homologacao) do |mdfe|
    #     mdfe.number 10
    #     mdfe.issuer_type :own_cargo
    #     mdfe.issuer cnpj: "...", name: "...", state_registration: "...", address: {...}
    #     mdfe.load_at "Sao Paulo", "SP"
    #     mdfe.unload_at "Rio de Janeiro", "RJ", nfe: ["3526..."]
    #     mdfe.road { |r| r.vehicle(plate: "ABC1D23", tare: 9000, wheels: :truck, body: :closed) { |v| v.driver "Fulano", "..." } }
    #     mdfe.cargo value: "15000.00", weight: "1200.5"
    #   end
    #   manifest.to_xml  # => the unsigned <MDFe>
    #
    # Whatever isn't given is defaulted or derived when the XML is produced (see Resolver).
    #
    # `certificate:` is needed only by a manifest issued in contingency, whose QR code
    # carries the access key signed with it. Client#build_manifest passes its own.
    #
    # `technical_contact:` is the software house's infRespTec ({cnpj:, contact:, email:,
    # phone:, csrt_id:, csrt:}); with `csrt:` the hashCSRT is computed for the key. The CSRT
    # itself never goes into the XML.
    class Manifest
      CONTINGENCY = "2"

      attr_reader :environment

      # `attributes` (or plain keywords) may hold any field: Manifest.new(number: 1, issuer: {...}).
      def initialize(attributes = nil, environment: Environment::HOMOLOGACAO, clock: Time, certificate: nil,
        technical_contact: nil, **fields)
        @environment = Environment.normalize(environment)
        @clock = clock
        @certificate = certificate
        @infmdfe = {}
        @memo = Resolver::Memo.new
        contact = (technical_contact || {}).transform_keys(&:to_sym)
        @csrt = contact.delete(:csrt)
        scope.technical_contact(contact) unless contact.empty?
        given = (attributes || {}).merge(fields)
        scope.__assign(given) unless given.empty?
        yield scope if block_given?
      end

      def scope = Scope.new(Schema.mdfe.find("infMDFe"), @infmdfe)

      # The tag-keyed values with defaults and derived fields filled in.
      def resolved = resolve.first

      def key
        tree, problems = resolve
        id = tree["@Id"] or raise ValidationError,
          problems.empty? ? ["cannot build the access key yet: fill in the issuer, series and number"] : problems
        AccessKey.parse(id.delete_prefix("MDFe"))
      end

      # The URL of the manifest's QR code (infMDFeSupl/qrCodMDFe), for the DAMDFE too. Nil
      # while the key can't be built, or in contingency without a certificate to sign it.
      def qr_code = qr_code_of(resolved)

      # The unsigned <MDFe> XML. Raises ValidationError when the manifest has problems.
      # `strict: false` skips the business rules and enforces only formatting and the schema.
      def to_xml(strict: true)
        xml, found = render(strict: strict)
        raise ValidationError, found unless found.empty?

        xml
      end

      # Every problem found locally (values, schema, business rules), as messages.
      def issues(strict: true) = render(strict: strict).last

      def valid?(strict: true) = issues(strict: strict).empty?

      def validate!(strict: true)
        found = issues(strict: strict)
        raise ValidationError, found unless found.empty?

        self
      end

      private

      # [the resolved tree, the problems met while resolving it]
      def resolve
        resolver = Resolver.new(environment: environment, memo: @memo, clock: @clock, csrt: @csrt)
        tree = resolver.call(@infmdfe)
        [tree, resolver.issues]
      end

      def contingency?(tree) = tree.dig("ide", "tpEmis").to_s == CONTINGENCY

      def qr_code_of(tree)
        id = tree["@Id"] or return
        return if contingency?(tree) && @certificate.nil?

        QrCode.url(key: id.delete_prefix("MDFe"), environment: tree.dig("ide", "tpAmb"),
          certificate: (@certificate if contingency?(tree)))
      end

      def render(strict:)
        tree, problems = resolve
        url = qr_code_of(tree)
        if url.nil? && tree["@Id"]
          problems += ["a manifest issued in contingency needs the certificate to sign its QR code: " \
            "build it with client.build_manifest or pass certificate: (MOC 9.2.2)"]
        end
        writer = XmlWriter.new
        xml = writer.write({"infMDFe" => tree, "infMDFeSupl" => ({"qrCodMDFe" => url} if url)}.compact)
        found = problems + writer.issues
        found.concat(Schemas.mdfe_issues(xml)) if found.empty?
        found.concat(Validator.new(tree, qr_code: url, clock: @clock, csrt: @csrt).issues) if strict
        [xml, found]
      end
    end
  end
end
