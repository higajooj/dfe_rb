module DfeRb
  module Nfe
    # The vocabulary of the builder: readable English names for the layout's fields (the XML
    # tag each one maps to), plus friendly symbols for coded values. Every field is also
    # reachable by its official tag ("xNome"), or as snake_case ("x_nome").
    module Names
      ADDRESS = {
        street: "xLgr", number: "nro", complement: "xCpl", district: "xBairro", city_code: "cMun",
        city: "xMun", state: "UF", zip: "CEP", country_code: "cPais", country: "xPais", phone: "fone",
        email: "email", cnpj: "CNPJ", cpf: "CPF", name: "xNome", state_registration: "IE"
      }.freeze

      ICMS = {
        origin: "orig", cst: "CST", csosn: "CSOSN", base_mode: "modBC", base: "vBC", base_reduction: "pRedBC",
        rate: "pICMS", amount: "vICMS", fcp_base: "vBCFCP", fcp_rate: "pFCP", fcp_amount: "vFCP",
        st_base_mode: "modBCST", st_margin: "pMVAST", st_base_reduction: "pRedBCST", st_base: "vBCST",
        st_rate: "pICMSST", st_amount: "vICMSST", st_fcp_base: "vBCFCPST", st_fcp_rate: "pFCPST",
        st_fcp_amount: "vFCPST", exemption_amount: "vICMSDeson", exemption_reason: "motDesICMS",
        exemption_deducted: "indDeduzDeson", operation_amount: "vICMSOp", deferral_rate: "pDif",
        deferral_amount: "vICMSDif", retained_st_base: "vBCSTRet", retained_st_rate: "pST",
        substitute_amount: "vICMSSubstituto", retained_st_amount: "vICMSSTRet", credit_rate: "pCredSN",
        credit_amount: "vCredICMSSN", benefit_code: "cBenefRBC", operation_base_rate: "pBCOp", st_state: "UFST",
        destination_st_base: "vBCSTDest", destination_st_amount: "vICMSSTDest", effective_base_reduction: "pRedBCEfet",
        effective_base: "vBCEfet", effective_rate: "pICMSEfet", effective_amount: "vICMSEfet",
        mono_base: "qBCMono", mono_ad_rem: "adRemICMS", mono_amount: "vICMSMono", mono_operation_amount: "vICMSMonoOp",
        mono_deferral_amount: "vICMSMonoDif", mono_deferral_base: "qBCMonoDif", mono_deferral_ad_rem: "adRemICMSDif",
        mono_retained_base: "qBCMonoReten", mono_retained_ad_rem: "adRemICMSReten", mono_retained_amount: "vICMSMonoReten",
        mono_ret_base: "qBCMonoRet", mono_ret_ad_rem: "adRemICMSRet", mono_ret_amount: "vICMSMonoRet"
      }.freeze

      PIS = {cst: "CST", base: "vBC", rate: "pPIS", amount: "vPIS", quantity_base: "qBCProd", unit_rate: "vAliqProd"}.freeze
      COFINS = {cst: "CST", base: "vBC", rate: "pCOFINS", amount: "vCOFINS", quantity_base: "qBCProd", unit_rate: "vAliqProd"}.freeze

      IPI = {
        cst: "CST", framework_code: "cEnq", base: "vBC", rate: "pIPI", amount: "vIPI", unit_quantity: "qUnid",
        unit_amount: "vUnid", stamp_code: "cSelo", stamp_quantity: "qSelo", producer_cnpj: "CNPJProd"
      }.freeze

      IBSCBS = {cst: "CST", class_code: "cClassTrib", donation: "indDoacao"}.freeze

      # Per element tag. "infNFe" is the invoice itself.
      FIELDS = {
        "infNFe" => {
          issuer: "emit", recipient: "dest", pickup: "retirada", delivery: "entrega", authorized_downloader: "autXML",
          shipping: "transp", transport: "transp", billing: "cobr", intermediary: "infIntermed",
          additional_info: "infAdic", export: "exporta", purchase: "compra", sugar_cane: "cana",
          technical_contact: "infRespTec", agro: "agropecuario", totals: "total", item: "det", items: "det",
          reference: "NFref"
        },
        "ide" => {
          state_code: "cUF", numeric_code: "cNF", nature_of_operation: "natOp", model: "mod", series: "serie",
          number: "nNF", issued_at: "dhEmi", departed_at: "dhSaiEnt", delivery_forecast: "dPrevEntrega",
          operation_type: "tpNF", destination: "idDest", city_code: "cMunFG", print_format: "tpImp",
          emission_type: "tpEmis", check_digit: "cDV", environment: "tpAmb", purpose: "finNFe",
          final_consumer: "indFinal", presence: "indPres", intermediary_indicator: "indIntermed",
          process: "procEmi", software_version: "verProc", contingency_at: "dhCont", contingency_reason: "xJust",
          debit_note_type: "tpNFDebito", credit_note_type: "tpNFCredito", operation_indicator: "cIndOp"
        },
        "emit" => {
          cnpj: "CNPJ", cpf: "CPF", name: "xNome", trade_name: "xFant", address: "enderEmit", state_registration: "IE",
          st_state_registration: "IEST", municipal_registration: "IM", cnae: "CNAE", tax_regime: "CRT"
        },
        "dest" => {
          cnpj: "CNPJ", cpf: "CPF", foreign_id: "idEstrangeiro", name: "xNome", address: "enderDest",
          state_registration_indicator: "indIEDest", state_registration: "IE", suframa: "ISUF",
          municipal_registration: "IM", email: "email"
        },
        "enderEmit" => ADDRESS, "enderDest" => ADDRESS, "retirada" => ADDRESS, "entrega" => ADDRESS,
        "det" => {
          code: "cProd", gtin: "cEAN", barcode: "cBarra", description: "xProd", ncm: "NCM", cest: "CEST",
          scale_indicator: "indEscala", manufacturer_cnpj: "CNPJFab", benefit_code: "cBenef", ex_tipi: "EXTIPI",
          cfop: "CFOP", unit: "uCom", quantity: "qCom", unit_price: "vUnCom", total: "vProd",
          taxable_gtin: "cEANTrib", taxable_unit: "uTrib", taxable_quantity: "qTrib",
          taxable_unit_price: "vUnTrib", freight: "vFrete", insurance: "vSeg", discount: "vDesc",
          other_expenses: "vOutro", counts_in_total: "indTot", order_number: "xPed", order_item: "nItemPed",
          fci: "nFCI", additional_info: "infAdProd", tax_total: "vTotTrib", ibs_cbs: "IBSCBS",
          selective_tax: "IS", icms_destination: "ICMSUFDest", import_tax: "II", returned_tax: "impostoDevol",
          referenced_dfe: "DFeReferenciado"
        },
        "NFref" => {key: "refNFe", nfe: "refNFe", cte: "refCTe"},
        "obsCont" => {field: "@xCampo", text: "xTexto"},
        "transp" => {
          freight_mode: "modFrete", mode: "modFrete", carrier: "transporta", retained_tax: "retTransp",
          vehicle: "veicTransp", trailers: "reboque", volumes: "vol", volume: "vol"
        },
        "transporta" => {cnpj: "CNPJ", cpf: "CPF", name: "xNome", state_registration: "IE", address: "xEnder", city: "xMun", state: "UF"},
        "veicTransp" => {plate: "placa", state: "UF", rntc: "RNTC"},
        "vol" => {
          quantity: "qVol", kind: "esp", brand: "marca", number: "nVol", net_weight: "pesoL",
          gross_weight: "pesoB", seals: "lacres"
        },
        "cobr" => {invoice: "fat", installments: "dup", installment: "dup"},
        "fat" => {number: "nFat", original_amount: "vOrig", discount: "vDesc", net_amount: "vLiq"},
        "dup" => {number: "nDup", due_date: "dVenc", amount: "vDup"},
        "pag" => {payments: "detPag", payment: "detPag", change: "vTroco"},
        "detPag" => {
          payment_type: "indPag", kind: "tPag", description: "xPag", amount: "vPag", paid_on: "dPag", card: "card"
        },
        "card" => {
          integration: "tpIntegra", cnpj: "CNPJ", brand: "tBand", authorization: "cAut", receiver_cnpj: "CNPJReceb",
          terminal: "idTermPag"
        },
        "infAdic" => {
          tax_authority_info: "infAdFisco", additional_info: "infCpl", taxpayer_notes: "obsCont",
          tax_authority_notes: "obsFisco", process_references: "procRef"
        },
        "infRespTec" => {cnpj: "CNPJ", contact: "xContato", email: "email", phone: "fone", csrt_id: "idCSRT", csrt_hash: "hashCSRT"},
        "exporta" => {exit_state: "UFSaidaPais", exit_place: "xLocExporta", dispatch_place: "xLocDespacho"},
        "infIntermed" => {cnpj: "CNPJ", identifier: "idCadIntTran"},
        "ICMSUFDest" => {
          destination_base: "vBCUFDest", destination_fcp_base: "vBCFCPUFDest", destination_fcp_rate: "pFCPUFDest",
          destination_rate: "pICMSUFDest", interstate_rate: "pICMSInter", partition_rate: "pICMSInterPart",
          destination_fcp_amount: "vFCPUFDest", destination_amount: "vICMSUFDest", origin_amount: "vICMSUFRemet"
        },
        "ISSQN" => {
          base: "vBC", rate: "vAliq", amount: "vISSQN", city_code: "cMunFG", service_list_item: "cListServ",
          deduction: "vDeducao", other: "vOutro", unconditional_discount: "vDescIncond", conditional_discount: "vDescCond",
          withheld_amount: "vISSRet", iss_indicator: "indISS", service_code: "cServico", city: "cMun",
          country: "cPais", process_number: "nProcesso", incentive: "indIncentivo"
        }
      }.freeze

      # Tags that share a vocabulary through a name prefix (ICMS00, ICMSSN102, PISAliq...).
      PREFIXES = [
        [/\AICMS(?!UFDest)/, ICMS], [/\APIS/, PIS], [/\ACOFINS/, COFINS], [/\AIPI/, IPI], [/\AIBSCBS\z/, IBSCBS]
      ].freeze

      ENUMS = {
        "CRT" => {simples: 1, simples_excess: 2, normal: 3, mei: 4},
        "tpNF" => {incoming: 0, entry: 0, outgoing: 1, exit: 1},
        "idDest" => {internal: 1, interstate: 2, foreign: 3},
        "tpEmis" => {normal: 1, epec: 4, svc_an: 6, svc_rs: 7, offline: 9},
        "tpImp" => {none: 0, portrait: 1, landscape: 2, simplified: 3, simplified_type_2: 6},
        "finNFe" => {normal: 1, complementary: 2, adjustment: 3, return: 4, credit_note: 5, debit_note: 6},
        "indFinal" => {no: 0, yes: 1},
        "indPres" => {not_applicable: 0, in_person: 1, internet: 2, phone: 3, home_delivery: 4, off_premises: 5, other: 9},
        "procEmi" => {own_software: 0, tax_office_software: 3, paa: 4},
        "indIEDest" => {taxpayer: 1, exempt: 2, non_taxpayer: 9},
        "modFrete" => {sender: 0, cif: 0, recipient: 1, fob: 1, third_party: 2, own_sender: 3, own_recipient: 4, none: 9},
        "tPag" => {
          money: "01", check: "02", credit_card: "03", debit_card: "04", store_credit: "05", food_voucher: "10",
          meal_voucher: "11", gift_voucher: "12", fuel_voucher: "13", commercial_installment: "14", bank_slip: "15",
          bank_deposit: "16", instant_payment: "17", pix: "17", bank_transfer: "18", cashback: "19",
          static_pix: "20", store_credit_card: "21", other_electronic: "22", automatic_pix: "23", book_transfer: "24",
          no_payment: "90", deferred_payment: "91", other: "99"
        },
        "indPag" => {cash: 0, installments: 1},
        "orig" => {
          domestic: 0, foreign_import: 1, foreign_acquired: 2, domestic_imported_content_over_40: 3,
          domestic_basic_production: 4, domestic_imported_content_up_to_40: 5, foreign_import_no_similar: 6,
          foreign_acquired_no_similar: 7, domestic_imported_content_over_70: 8
        },
        "modBC" => {margin: 0, unit_price: 1, price_list: 2, operation_value: 3},
        "tpIntegra" => {integrated: 1, not_integrated: 2}
      }.freeze

      module_function

      # snake_case form of an official tag: "vBCSTRet" => "v_bcst_ret".
      def snake(tag)
        tag.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
      end

      # English name => tag table for an element tag.
      def table_for(tag)
        FIELDS[tag] || PREFIXES.find { |pattern, _| pattern.match?(tag) }&.last || {}
      end

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
