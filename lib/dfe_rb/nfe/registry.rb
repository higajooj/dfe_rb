require "date"

module DfeRb
  module Nfe
    # One registration in a state's ICMS cadastro (infCad of NfeConsultaCadastro, MOC 5.6).
    # A taxpayer has one per establishment, and a state answers with all that match.
    #
    # situation: 1 enabled, 0 not. nfe_accreditation (indCredNFe): 0 not accredited to issue
    # NF-e, 1 accredited, 2 and 3 obliged for all or some operations, 4 not told by the state.
    # address: the builder's names (street, number, complement, district, city_code, city,
    # zip), with only what the state gives.
    Taxpayer = Data.define(
      :state_registration, :cnpj, :cpf, :state, :situation, :nfe_accreditation, :cte_accreditation, :name, :trade_name,
      :regime, :cnae, :started_on, :situation_changed_on, :closed_on, :single_state_registration,
      :current_state_registration, :address
    ) do
      def active? = situation == 1

      def tax_id = cnpj || cpf
    end

    # The answer to a consulta cadastro. `found?` is cStat 111 (one registration) or 112
    # (more than one); anything else is a rejection, such as 259 (CNPJ not in the cadastro).
    RegistryResult = Data.define(:code, :message, :state, :consulted_at, :taxpayers, :request_xml, :xml) do
      def found? = StatusCodes::TAXPAYER_FOUND.include?(code)
    end

    # Reads <retConsCad>.
    module Registry
      ADDRESS = {
        street: "xLgr", number: "nro", complement: "xCpl", district: "xBairro", city_code: "cMun", city: "xMun", zip: "CEP"
      }.freeze

      module_function

      def parse(xml, request_xml: nil)
        response = Response.new(xml)
        RegistryResult.new(
          code: response.code, message: response.message, state: response.text("infCons/UF"),
          consulted_at: response.text("infCons/dhCons"), taxpayers: response.nodes("infCad").map { |node| taxpayer(node) },
          request_xml: request_xml, xml: response.xml
        )
      end

      def taxpayer(node)
        text = ->(tag) { node.at_xpath("./#{tag}")&.text&.strip.then { |value| value unless value.to_s.empty? } }
        address = node.at_xpath("./ender")
        Taxpayer.new(
          state_registration: text["IE"], cnpj: text["CNPJ"], cpf: text["CPF"], state: text["UF"],
          situation: text["cSit"]&.to_i, nfe_accreditation: text["indCredNFe"]&.to_i, cte_accreditation: text["indCredCTe"]&.to_i,
          name: text["xNome"], trade_name: text["xFant"], regime: text["xRegApur"], cnae: text["CNAE"],
          started_on: date(text["dIniAtiv"]), situation_changed_on: date(text["dUltSit"]), closed_on: date(text["dBaixa"]),
          single_state_registration: text["IEUnica"], current_state_registration: text["IEAtual"],
          address: address ? address_of(address) : {}
        )
      end

      def address_of(node)
        ADDRESS.filter_map do |name, tag|
          value = node.at_xpath("./#{tag}")&.text&.strip
          [name, value] unless value.to_s.empty?
        end.to_h
      end

      def date(value)
        Date.iso8601(value) if value
      rescue Date::Error
        nil
      end
    end
  end
end
