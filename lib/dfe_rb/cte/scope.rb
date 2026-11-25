module DfeRb
  module Cte
    module Vocabulary
      FLATTEN = {
        "infCte" => %w[ide vPrest imp infCTeNorm],
        "infCTeNorm" => %w[infCarga infDoc],
        "IBSCBS" => %w[gIBSCBS]
      }.freeze

      PATHS = {
        "infCte" => {
          road: %w[infCTeNorm infModal rodo],
          air: %w[infCTeNorm infModal aereo],
          water: %w[infCTeNorm infModal aquav],
          rail: %w[infCTeNorm infModal ferrov],
          pipeline: %w[infCTeNorm infModal duto],
          multimodal: %w[infCTeNorm infModal multimodal]
        }
      }.freeze

      POSITIONAL = {
        "Comp" => %i[name amount],
        "infQ" => %i[unit quantity kind],
        "infNFe" => %i[key],
        "infDCe" => %i[key],
        "infCTeMultimodal" => %i[key],
        "infCteComp" => %i[key],
        "dup" => %i[due_on amount],
        "ObsCont" => %i[field text],
        "ObsFisco" => %i[field text]
      }.freeze

      module_function

      def flatten = FLATTEN

      def paths = PATHS

      def positional = POSITIONAL

      def counter = nil

      def label = "DfeRb::Cte::Scope"

      def table_for(tag) = Names.table_for(tag)

      def snake(tag) = Names.snake(tag)

      def enum_value(tag, symbol) = Names.enum_value(tag, symbol)

      def handler(tag, key) = Sugar.handler(tag, key)
    end

    class Scope < DfeRb::Scope
      def initialize(element, data, vocabulary = Vocabulary) = super
    end
  end
end
