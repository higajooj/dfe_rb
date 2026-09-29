module DfeRb
  module Nfe
    # An NF-e being put together. Fill it through the builder block, a hash, or both:
    #
    #   invoice = DfeRb::Nfe::Invoice.new(environment: :homologacao) do |nfe|
    #     nfe.number 1
    #     nfe.nature_of_operation "Venda"
    #     nfe.issuer cnpj: "...", name: "...", tax_regime: :simples, address: {...}
    #     nfe.item { |i| i.description "Widget"; i.quantity 2; i.unit_price "10.00" }
    #   end
    #   invoice.to_xml  # => the unsigned <NFe>
    #
    # Whatever isn't given is defaulted or derived when the XML is produced (see Resolver).
    class Invoice
      attr_reader :environment

      # `attributes` (or plain keywords) may hold any field: Invoice.new(number: 1, issuer: {...}).
      def initialize(attributes = nil, environment: Environment::HOMOLOGACAO, clock: Time, **fields)
        @environment = Environment.normalize(environment)
        @clock = clock
        @infnfe = {}
        @memo = Resolver::Memo.new
        given = (attributes || {}).merge(fields)
        scope.__assign(given) unless given.empty?
        yield scope if block_given?
      end

      # The builder scope for the whole invoice.
      def scope = Scope.new(Schema.nfe.find("infNFe"), @infnfe)

      # The tag-keyed values with defaults and derived fields filled in.
      def resolved = resolve.first

      def key
        tree, problems = resolve
        id = tree["@Id"] or raise ValidationError,
          problems.empty? ? ["cannot build the access key yet: fill in the issuer, series, number and issue date"] : problems
        AccessKey.parse(id.delete_prefix("NFe"))
      end

      # The unsigned <NFe> XML. Raises ValidationError when the invoice has problems; with
      # `strict: false` the business rules are skipped and only formatting and the schema are
      # enforced.
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
        resolver = Resolver.new(environment: environment, memo: @memo, clock: @clock)
        tree = resolver.call(@infnfe)
        [tree, resolver.issues]
      end

      def render(strict:)
        tree, problems = resolve
        writer = XmlWriter.new
        xml = writer.write("infNFe" => tree)
        found = problems + writer.issues
        found.concat(Schemas.nfe_issues(xml)) if found.empty?
        found.concat(Validator.new(tree).issues) if strict
        [xml, found]
      end
    end
  end
end
