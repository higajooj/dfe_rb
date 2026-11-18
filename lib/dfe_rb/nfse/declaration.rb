module DfeRb
  module Nfse
    # A DPS (Declaração de Prestação de Serviço) being put together: what the issuer sends
    # the Sefin Nacional, which answers with the NFS-e. Fill it through the builder block, a
    # hash, or both:
    #
    #   dps = DfeRb::Nfse::Declaration.new(environment: :homologacao) do |d|
    #     d.city "Campo Grande", "MS"
    #     d.number 1
    #     d.provider cnpj: "...", simples: :me_epp, simples_regime: :simples, special_regime: :none
    #     d.taker cnpj: "...", name: "...", address: {street: "...", number: "1", district: "...", city_code: "5002704", zip: "79002000"}
    #     d.service national_code: "010101", description: "Desenvolvimento de software", city_code: "5002704"
    #     d.amount "1000.00"
    #     d.issqn :taxable
    #     d.withholding :none
    #     d.approximate_taxes simples_rate: "6.00"
    #   end
    #   dps.to_xml  # => the unsigned <DPS>
    #
    # Whatever isn't given is defaulted or derived when the XML is produced (see Resolver).
    # `layout:` picks the DPS layout (Layouts); by default the one the environment validates.
    class Declaration
      attr_reader :environment, :layout

      # `attributes` (or plain keywords) may hold any field: Declaration.new(number: 1, provider: {...}).
      # `city:` is the issuing city (cLocEmi), as an IBGE code or a [name, state] pair.
      def initialize(attributes = nil, environment: Environment::HOMOLOGACAO, layout: nil, clock: Time, city: nil, **fields)
        @environment = Environment.normalize(environment)
        @layout = layout ? Layouts.fetch(layout) : Layouts.default(@environment)
        @clock = clock
        @infdps = {}
        @memo = Resolver::Memo.new
        scope.city(*Array(city)) if city
        given = (attributes || {}).merge(fields)
        scope.__assign(given) unless given.empty?
        yield scope if block_given?
      end

      def scope = Scope.new(@layout.dps.find("infDPS"), @infdps)

      # The tag-keyed values with defaults and derived fields filled in.
      def resolved = resolve.first

      # The DPS Id ("DPS" + 42 digits), which finds the NFS-e generated from it.
      def id
        tree, problems = resolve
        tree["@Id"] or raise ValidationError, problems
      end

      # The unsigned <DPS> XML. Raises ValidationError when the declaration has problems.
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

      def resolve
        resolver = Resolver.new(environment: environment, layout: @layout, memo: @memo, clock: @clock)
        tree = resolver.call(@infdps)
        [tree, resolver.issues]
      end

      def render(strict:)
        tree, problems = resolve
        writer = XmlWriter.new(@layout.dps, namespace: NAMESPACE)
        xml = writer.write({"@versao" => @layout.version, "infDPS" => tree})
        found = problems + writer.issues
        found.concat(@layout.dps_issues(xml)) if found.empty?
        found.concat(Validator.new(tree, layout: @layout).issues) if strict
        [xml, found.uniq]
      end
    end
  end
end
