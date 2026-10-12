module DfeRb
  module Nfe
    # The states (DfeRb::States) and the SEFAZ that authorizes each one's NF-e: the state's
    # own (:own), the SEFAZ Virtual do Ambiente Nacional (:svan) or the SEFAZ Virtual RS (:svrs).
    module States
      include DfeRb::States
      extend self

      OWN_AUTHORIZER = %w[AM BA GO MG MS MT PE PR RS SP].freeze
      SVAN = %w[MA].freeze
      # States whose contingency authorizer is the SVC-AN; the others use the SVC-RS (Portal
      # Nacional da NF-e, "Autorizadores em contingência", which updates Anexo III 2.1.3.1).
      SVC_AN = %w[AC AL AP CE DF ES MG PA PB PI RJ RN RO RR RS SC SE SP TO].freeze
      SVC_EMISSION_TYPES = {"SVC-AN" => 6, "SVC-RS" => 7}.freeze
      # States whose taxpayers can't register an EPEC (Ajuste SINIEF 25/2026, RV 2P10-20).
      EPEC_BARRED = %w[PR PB].freeze

      # Name of the SEFAZ that authorizes the state's NF-e: an own-authorizer state
      # abbreviation ("SP"), "SVAN" or "SVRS".
      def authorizer(state)
        uf = abbreviation(state)
        if OWN_AUTHORIZER.include?(uf)
          uf
        elsif SVAN.include?(uf)
          "SVAN"
        else
          "SVRS"
        end
      end

      # The SEFAZ Virtual de Contingência that authorizes the state's NF-e while its own
      # authorizer is down: "SVC-AN" or "SVC-RS".
      def contingency(state) = SVC_AN.include?(abbreviation(state)) ? "SVC-AN" : "SVC-RS"

      # tpEmis of a note sent to the state's SVC: 6 (SVC-AN) or 7 (SVC-RS).
      def contingency_emission_type(state) = SVC_EMISSION_TYPES.fetch(contingency(state))
    end
  end
end
