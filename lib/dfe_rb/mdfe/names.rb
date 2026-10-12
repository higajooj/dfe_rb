module DfeRb
  module Mdfe
    # The vocabulary of the builder: readable English names for the layout's fields (the XML
    # tag each one maps to), plus friendly symbols for coded values. Every field is also
    # reachable by its official tag ("xNome"), or as snake_case ("x_nome"). The road modal
    # is named in full; the others are filled by tag.
    module Names
      ADDRESS = {
        street: "xLgr", number: "nro", complement: "xCpl", district: "xBairro", city_code: "cMun",
        city: "xMun", state: "UF", zip: "CEP", phone: "fone", email: "email"
      }.freeze

      PARTY = {cnpj: "CNPJ", cpf: "CPF", name: "xNome", foreign_id: "idEstrangeiro"}.freeze

      DOCUMENT = {
        barcode: "SegCodBarra", redelivery: "indReentrega", transport_unit: "infUnidTransp", dangerous: "peri",
        partial_delivery: "infEntregaParcial"
      }.freeze

      VEHICLE = {
        internal_code: "cInt", plate: "placa", renavam: "RENAVAM", tare: "tara", capacity_kg: "capKG",
        capacity_m3: "capM3", owner: "prop", driver: "condutor", drivers: "condutor", wheels: "tpRod", body: "tpCar",
        state: "UF"
      }.freeze

      PLACE = {zip: "CEP", latitude: "latitude", longitude: "longitude"}.freeze

      # Per element tag. "infMDFe" is the manifest itself.
      FIELDS = {
        "infMDFe" => {
          issuer: "emit", documents: "infDoc", insurance: "seg", main_product: "prodPred", totals: "tot",
          seal: "lacres", seals: "lacres", additional_info: "infAdic", technical_contact: "infRespTec"
        },
        "ide" => {
          state_code: "cUF", environment: "tpAmb", issuer_type: "tpEmit", carrier_type: "tpTransp", model: "mod",
          series: "serie", number: "nMDF", numeric_code: "cMDF", check_digit: "cDV", issued_at: "dhEmi",
          emission_type: "tpEmis", process: "procEmi", software_version: "verProc", start_state: "UFIni",
          end_state: "UFFim", trip_starts_at: "dhIniViagem", green_channel: "indCanalVerde",
          later_loading: "indCarregaPosterior"
        },
        "emit" => PARTY.merge(trade_name: "xFant", address: "enderEmit", state_registration: "IE"),
        "enderEmit" => ADDRESS,
        "infMunDescarga" => {city_code: "cMunDescarga", city: "xMunDescarga", cte: "infCTe", nfe: "infNFe", mdfe: "infMDFeTransp"},
        "infCTe" => DOCUMENT.merge(key: "chCTe"),
        "infNFe" => DOCUMENT.merge(key: "chNFe"),
        "infMDFeTransp" => DOCUMENT.merge(key: "chMDFe"),
        "peri" => {
          un_number: "nONU", shipping_name: "xNomeAE", risk_class: "xClaRisco", packing_group: "grEmb",
          quantity: "qTotProd", volumes: "qVolTipo"
        },
        "seg" => {insurer: "infSeg", policy: "nApol", endorsement: "nAver", endorsements: "nAver"},
        "infResp" => {responsible: "respSeg", cnpj: "CNPJ", cpf: "CPF"},
        "infSeg" => {name: "xSeg", cnpj: "CNPJ"},
        "prodPred" => {kind: "tpCarga", description: "xProd", gtin: "cEAN", ncm: "NCM", full_load: "infLotacao"},
        "infLotacao" => {loading: "infLocalCarrega", unloading: "infLocalDescarrega"},
        "infLocalCarrega" => PLACE, "infLocalDescarrega" => PLACE,
        "tot" => {
          cte_count: "qCTe", nfe_count: "qNFe", mdfe_count: "qMDFe", cargo_value: "vCarga", cargo_unit: "cUnid",
          cargo_weight: "qCarga"
        },
        "lacres" => {number: "nLacre"}, "lacRodo" => {number: "nLacre"},
        "infAdic" => {tax_authority: "infAdFisco", notes: "infCpl"},
        "infRespTec" => {cnpj: "CNPJ", contact: "xContato", email: "email", phone: "fone", csrt_id: "idCSRT", csrt_hash: "hashCSRT"},
        "rodo" => {vehicle: "veicTracao", trailer: "veicReboque", trailers: "veicReboque", port_agency: "codAgPorto", seal: "lacRodo", seals: "lacRodo"},
        "infANTT" => {rntrc: "RNTRC", ciot: "infCIOT", contractor: "infContratante", contractors: "infContratante", freight_payment: "infPag"},
        "infCIOT" => {code: "CIOT", cnpj: "CNPJ", cpf: "CPF"},
        "valePed" => {toll_voucher: "disp", toll_vouchers: "disp", vehicle_category: "categCombVeic"},
        "disp" => {supplier: "CNPJForn", payer_cnpj: "CNPJPg", payer_cpf: "CPFPg", receipt: "nCompra", amount: "vValePed", kind: "tpValePed"},
        "infContratante" => PARTY.merge(contract: "infContrato"),
        "infContrato" => {number: "NroContrato", total: "vContratoGlobal"},
        "infPag" => PARTY.merge(
          component: "Comp", components: "Comp", total: "vContrato", high_performance: "indAltoDesemp", terms: "indPag",
          advance: "vAdiant", advance_anticipation: "indAntecipaAdiant", installment: "infPrazo",
          installments: "infPrazo", anticipation: "tpAntecip", bank: "infBanc"
        ),
        "Comp" => {kind: "tpComp", amount: "vComp", description: "xComp"},
        "infPrazo" => {number: "nParcela", due_on: "dVenc", amount: "vParcela"},
        "infBanc" => {bank_code: "codBanco", branch: "codAgencia", payment_institution: "CNPJIPEF", pix: "PIX"},
        "veicTracao" => VEHICLE, "veicReboque" => VEHICLE,
        "prop" => PARTY.merge(rntrc: "RNTRC", state_registration: "IE", state: "UF", kind: "tpProp"),
        "condutor" => {name: "xNome", cpf: "CPF"}
      }.freeze

      ENUMS = {
        "tpEmit" => {carrier: 1, own_cargo: 2, globalized_cte: 3},
        "tpTransp" => {etc: 1, tac: 2, ctc: 3},
        "modal" => {road: 1, air: 2, water: 3, rail: 4},
        "tpEmis" => {normal: 1, contingency: 2, nff: 3},
        "procEmi" => {own_software: 0, paa: 4},
        "respSeg" => {issuer: 1, contractor: 2},
        "tpCarga" => {
          bulk_solid: "01", bulk_liquid: "02", refrigerated: "03", containerized: "04", general: "05", neo_bulk: "06",
          dangerous_bulk_solid: "07", dangerous_bulk_liquid: "08", dangerous_refrigerated: "09",
          dangerous_containerized: "10", dangerous_general: "11", pressurized_bulk: "12"
        },
        "cUnid" => {kg: "01", ton: "02"},
        "tpRod" => {truck: "01", toco: "02", tractor: "03", van: "04", utility: "05", other: "06"},
        "tpCar" => {none: "00", open: "01", closed: "02", bulk: "03", container: "04", sider: "05"},
        "tpProp" => {tac_aggregate: 0, tac_independent: 1, other: 2},
        "tpValePed" => {tag: "01", plate_reading: "04"},
        "tpComp" => {toll: "01", taxes: "02", expenses: "03", freight: "04", other: "99"},
        "indPag" => {cash: 0, installments: 1},
        "tpAntecip" => {forbidden: 0, allowed: 1, on_confirmation: 2}
      }.freeze

      module_function

      # snake_case form of an official tag: "cMunCarrega" => "c_mun_carrega".
      def snake(tag)
        tag.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
      end

      # English name => tag table for an element tag.
      def table_for(tag) = FIELDS[tag] || {}

      # The coded value for a friendly symbol on the field `tag`.
      def enum_value(tag, symbol)
        table = ENUMS[tag]
        return symbol.to_s unless table

        table.fetch(symbol) do
          raise ArgumentError, "unknown value #{symbol.inspect} for #{tag} (use #{table.keys.map(&:inspect).join(", ")})"
        end
      end
    end
  end
end
