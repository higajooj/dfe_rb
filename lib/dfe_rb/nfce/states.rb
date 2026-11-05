module DfeRb
  module Nfce
    # The states (DfeRb::States) and the SEFAZ that authorizes each one's NFC-e: the state's
    # own or the SEFAZ Virtual RS. The list differs from the NF-e's: BA and PE have their NF-e
    # authorized at home but their NFC-e at the SVRS, and MA, served by the SVAN for the NF-e,
    # goes to the SVRS too ("Relação de Serviços Web" of the SVRS DF-e portal, and the answer
    # of each authorizer's status service).
    module States
      include DfeRb::States
      extend self

      OWN_AUTHORIZER = %w[AM GO MG MS MT PR RS SP].freeze

      # Name of the SEFAZ that authorizes the state's NFC-e: its abbreviation ("SP") or "SVRS".
      def authorizer(state)
        uf = abbreviation(state)
        OWN_AUTHORIZER.include?(uf) ? uf : "SVRS"
      end
    end
  end
end
