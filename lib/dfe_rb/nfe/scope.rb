module DfeRb
  module Nfe
    # What the NF-e layout says to the builder (DfeRb::Scope): its names, the levels it
    # flattens and its conveniences.
    module Vocabulary
      # Levels whose fields are reachable straight from their parent's scope.
      FLATTEN = {"infNFe" => %w[ide], "det" => %w[prod imposto]}.freeze

      # Entries whose English name stands for a path rather than a single child.
      PATHS = {
        "infNFe" => {payment: %w[pag detPag], payments: %w[pag detPag]}
      }.freeze

      # Positional shorthands for groups: `payment :money, "10.00"`.
      POSITIONAL = {
        "detPag" => %i[kind amount],
        "NFref" => %i[key],
        "gCred" => %i[code rate amount],
        "obsCont" => %i[field text]
      }.freeze

      module_function

      def flatten = FLATTEN

      def paths = PATHS

      def positional = POSITIONAL

      # The attribute that numbers a repeated group (det/@nItem).
      def counter = "nItem"

      def label = "DfeRb::Nfe::Scope"

      def table_for(tag) = Names.table_for(tag)

      def snake(tag) = Names.snake(tag)

      def enum_value(tag, symbol) = Names.enum_value(tag, symbol)

      def handler(tag, key) = Sugar.handler(tag, key)
    end

    # DfeRb::NameIndex with the NF-e vocabulary.
    class NameIndex < DfeRb::NameIndex
      FLATTEN = Vocabulary::FLATTEN
      PATHS = Vocabulary::PATHS

      def self.for(element, vocabulary = Vocabulary) = DfeRb::NameIndex.for(element, vocabulary)
    end

    # The object handed to the invoice's builder blocks: DfeRb::Scope with the NF-e vocabulary.
    class Scope < DfeRb::Scope
      POSITIONAL = Vocabulary::POSITIONAL

      def initialize(element, data, vocabulary = Vocabulary) = super
    end
  end
end
