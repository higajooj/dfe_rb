module DfeRb
  module Mdfe
    # What the MDF-e layout says to the builder (DfeRb::Scope): its names, the levels it
    # flattens and its conveniences.
    module Vocabulary
      # Levels whose fields are reachable straight from their parent's scope.
      FLATTEN = {"infMDFe" => %w[ide tot], "rodo" => %w[infANTT], "infANTT" => %w[valePed], "seg" => %w[infResp]}.freeze

      # Entries whose English name stands for a path rather than a single child.
      PATHS = {
        "infMDFe" => {road: %w[infModal rodo], air: %w[infModal aereo], water: %w[infModal aquav], rail: %w[infModal ferrov]}
      }.freeze

      # Positional shorthands for groups: `driver "Fulano", "12345678909"`.
      POSITIONAL = {
        "condutor" => %i[name cpf],
        "infCTe" => %i[key], "infNFe" => %i[key], "infMDFeTransp" => %i[key],
        "infCIOT" => %i[code],
        "prodPred" => %i[description],
        "lacres" => %i[number], "lacRodo" => %i[number],
        "Comp" => %i[kind amount],
        "infPrazo" => %i[due_on amount]
      }.freeze

      module_function

      def flatten = FLATTEN

      def paths = PATHS

      def positional = POSITIONAL

      def counter = nil

      def label = "DfeRb::Mdfe::Scope"

      def table_for(tag) = Names.table_for(tag)

      def snake(tag) = Names.snake(tag)

      def enum_value(tag, symbol) = Names.enum_value(tag, symbol)

      def handler(tag, key) = Sugar.handler(tag, key)
    end

    # The object handed to the manifest's builder blocks: DfeRb::Scope with the MDF-e vocabulary.
    class Scope < DfeRb::Scope
      def initialize(element, data, vocabulary = Vocabulary) = super
    end
  end
end
