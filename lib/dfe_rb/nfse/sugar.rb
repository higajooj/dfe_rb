module DfeRb
  module Nfse
    # Builder conveniences that don't map 1:1 to a schema child: the issuing city by name,
    # `tax_id`, which picks CNPJ or CPF, and the approximate taxes of Lei 12.741/2012.
    module Sugar
      HANDLERS = {}

      class << self
        def handler(tag, key) = HANDLERS[[tag, key]]

        def register(tag, key, &block)
          HANDLERS[[tag, key]] = block
        end

        def tax_id(data, value)
          id = TaxId.normalize(value)
          data.delete("CNPJ")
          data.delete("CPF")
          data[(id.length == 11) ? "CPF" : "CNPJ"] = id
          nil
        end

        def attributes(args, kwargs)
          first = args.first
          first.is_a?(Hash) ? first.merge(kwargs) : kwargs
        end
      end

      # `city "Campo Grande", "MS"` or `city "5002704"`: where the issuer is registered to
      # issue (cLocEmi).
      register("infDPS", "city") do |_scope, data, args, kwargs, _block|
        data["cLocEmi"] = Mdfe::Sugar.city(args, kwargs).first
        nil
      end

      # A CNPJ or CPF, told apart by length: `provider tax_id: "..."`.
      %w[prest toma interm fornec dest].each do |tag|
        register(tag, "tax_id") { |_scope, data, args, _kwargs, _block| tax_id(data, args.first) }
      end

      # The approximate taxes on the service (Lei 12.741/2012, totTrib): amounts, rates, the
      # Simples Nacional's single rate, or none.
      #
      #   dps.approximate_taxes federal: "13.45", state: "0.00", municipal: "5.00"
      #   dps.approximate_taxes rates: {federal: "13.45", state: "0.00", municipal: "5.00"}
      #   dps.approximate_taxes simples_rate: "6.00"
      #   dps.approximate_taxes :not_informed     # indTotTrib 0, for a MEI
      {
        "infDPS" => ->(data) { (data["valores"] ||= {})["trib"] ||= {} },
        "valores" => ->(data) { data["trib"] ||= {} },
        "trib" => ->(data) { data }
      }.each do |tag, trib|
        register(tag, "approximate_taxes") do |_scope, data, args, kwargs, _block|
          trib.call(data)["totTrib"] = approximate_taxes(args, kwargs)
          nil
        end
      end

      def self.approximate_taxes(args, kwargs)
        return {"indTotTrib" => 0} if args.first == :not_informed

        options = attributes(args, kwargs).transform_keys(&:to_sym)
        return {"pTotTribSN" => options.fetch(:simples_rate)} if options.key?(:simples_rate)

        if options.key?(:rates)
          rates = options.fetch(:rates).transform_keys(&:to_sym)
          return {"pTotTrib" => {"pTotTribFed" => rates.fetch(:federal), "pTotTribEst" => rates.fetch(:state), "pTotTribMun" => rates.fetch(:municipal)}}
        end

        {"vTotTrib" => {"vTotTribFed" => options.fetch(:federal), "vTotTribEst" => options.fetch(:state), "vTotTribMun" => options.fetch(:municipal)}}
      rescue KeyError => e
        raise ArgumentError, "approximate_taxes takes federal:, state: and municipal:, rates: {...}, simples_rate: or :not_informed (#{e.message})"
      end
    end

    # What the DPS layout says to the builder (DfeRb::Scope): its names, the levels it
    # flattens and its conveniences.
    module Vocabulary
      # Levels whose fields are reachable straight from their parent's scope.
      FLATTEN = {
        "infDPS" => %w[valores], "prest" => %w[regTrib], "end" => %w[endNac], "serv" => %w[locPrest cServ infoCompl],
        "valores" => %w[vServPrest vDescCondIncond trib], "trib" => %w[tribMun tribFed gIBSCBS], "IBSCBS" => %w[valores]
      }.freeze

      # Positional shorthands for groups: `replaces "3550...", reason: :other`.
      POSITIONAL = {"subst" => %i[key]}.freeze

      module_function

      def flatten = FLATTEN

      def paths = {}

      def positional = POSITIONAL

      def counter = nil

      def label = "DfeRb::Nfse::Scope"

      def table_for(tag) = Names.table_for(tag)

      def snake(tag) = Names.snake(tag)

      def enum_value(tag, symbol) = Names.enum_value(tag, symbol)

      def handler(tag, key) = Sugar.handler(tag, key)
    end

    # The object handed to the declaration's builder blocks: DfeRb::Scope with the DPS vocabulary.
    class Scope < DfeRb::Scope
      def initialize(element, data, vocabulary = Vocabulary) = super
    end
  end
end
