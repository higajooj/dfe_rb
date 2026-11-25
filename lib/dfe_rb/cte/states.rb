module DfeRb
  module Cte
    module States
      include DfeRb::States
      extend self

      OWN_AUTHORIZER = %w[MG MS MT PR SP].freeze
      SVSP = %w[AP PE RR].freeze
      SVC_RS_AUTHORIZERS = %w[MS MT SP SVSP].freeze
      SVC_EMISSION_TYPES = {"SVC-RS" => 7, "SVC-SP" => 8}.freeze

      def authorizer(state)
        uf = abbreviation(state)
        if OWN_AUTHORIZER.include?(uf)
          uf
        elsif SVSP.include?(uf)
          "SVSP"
        else
          "SVRS"
        end
      end

      def contingency(state)
        SVC_RS_AUTHORIZERS.include?(authorizer(state)) ? "SVC-RS" : "SVC-SP"
      end

      def contingency_emission_type(state) = SVC_EMISSION_TYPES.fetch(contingency(state))
    end
  end
end
