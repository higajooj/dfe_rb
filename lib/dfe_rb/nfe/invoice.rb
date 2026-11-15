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
    #
    # `technical_contact:` is the software house's infRespTec ({cnpj:, contact:, email:,
    # phone:, csrt_id:, csrt:}); with `csrt:` the hashCSRT is computed for each key. The CSRT
    # itself never goes into the XML.
    #
    # A note printed as the DANFE Simplificado Tipo 2 (`nfe.print_format :simplified_type_2`,
    # tpImp 6), an NF-e for a sale an NFC-e would cover (NT 2026.002), carries the NFC-e's
    # QR code in infNFeSupl and follows the NFC-e's rules (Nfce::Validator). `certificate:`
    # signs its QR code when it is issued off-line; Client#build_invoice passes its own.
    # `endpoints:` may override the state's QR code and consultation addresses (:qr_code,
    # :consult_url).
    class Invoice
      # The mod the note gets (DfeRb::Nfce::Invoice is 65).
      MODEL = 55

      attr_reader :environment

      # `attributes` (or plain keywords) may hold any field: Invoice.new(number: 1, issuer: {...}).
      def initialize(attributes = nil, environment: Environment::HOMOLOGACAO, clock: Time, technical_contact: nil,
        certificate: nil, endpoints: {}, **fields)
        @environment = Environment.normalize(environment)
        @certificate = certificate
        @addresses = endpoints
        @clock = clock
        @infnfe = {}
        @memo = Resolver::Memo.new
        contact = (technical_contact || {}).transform_keys(&:to_sym)
        @csrt = contact.delete(:csrt)
        scope.technical_contact(contact) unless contact.empty?
        given = (attributes || {}).merge(fields)
        scope.__assign(given) unless given.empty?
        yield scope if block_given?
      end

      def scope = Scope.new(Schema.nfe.find("infNFe"), @infnfe)

      # The tag-keyed values with defaults and derived fields filled in.
      def resolved = resolve.first

      def key
        tree, problems = resolve
        id = tree["@Id"] or raise ValidationError,
          problems.empty? ? ["cannot build the access key yet: fill in the issuer, series, number and issue date"] : problems
        AccessKey.parse(id.delete_prefix("NFe"))
      end

      # The unsigned <NFe> XML. Raises ValidationError when the invoice has problems.
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

      # infNFeSupl/qrCode: the URL the QR code of the DANFE NFC-e or the DANFE Simplificado
      # Tipo 2 holds. Nil for a note printed otherwise, while the key can't be built, or
      # off-line without a certificate to sign it.
      def qr_code = supplement_of(resolved).first&.fetch("qrCode")

      # infNFeSupl/urlChave: where the buyer looks the note up by its key; nil without a QR code.
      def consult_url = supplement_of(resolved).first&.fetch("urlChave")

      private

      # [the resolved tree, the problems met while resolving it]
      def resolve
        resolver = Resolver.new(environment: environment, memo: @memo, clock: @clock, csrt: @csrt, model: self.class::MODEL)
        tree = resolver.call(@infnfe)
        [tree, resolver.issues]
      end

      def render(strict:)
        tree, problems = resolve
        supplement, missing = supplement_of(tree)
        writer = XmlWriter.new
        xml = writer.write({"infNFe" => tree, "infNFeSupl" => supplement}.compact)
        found = problems + missing + writer.issues
        found.concat(Schemas.nfe_issues(xml)) if found.empty?
        found.concat(rule_issues(tree, supplement)) if strict
        [xml, found]
      end

      # [infNFeSupl, problems building it]: none for a note without a QR code.
      def supplement_of(tree)
        return [nil, []] unless Nfce::Supplement.carried_by?(tree["ide"])

        Nfce::Supplement.build(tree, certificate: @certificate, overrides: @addresses)
      end

      # The NF-e's rules, and the NFC-e's for a note that prints like one (NT 2026.002).
      def rule_issues(tree, supplement)
        found = Validator.new(tree, csrt: @csrt).issues
        return found unless Nfce::Supplement.carried_by?(tree["ide"])

        found + Nfce::Validator.new(tree, supplement: supplement, signer: @certificate&.certificate, now: @clock.now).issues
      end
    end
  end
end
