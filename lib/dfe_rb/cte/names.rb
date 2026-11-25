module DfeRb
  module Cte
    module Names
      ADDRESS = {
        street: "xLgr", number: "nro", complement: "xCpl", district: "xBairro", city_code: "cMun",
        city: "xMun", zip: "CEP", state: "UF", country_code: "cPais", country: "xPais", phone: "fone"
      }.freeze

      PARTY = {
        cnpj: "CNPJ", cpf: "CPF", state_registration: "IE", name: "xNome", trade_name: "xFant",
        phone: "fone", email: "email"
      }.freeze

      IBS_CBS_RATE_FIELDS = {
        deferral: "gDif", tax_return: "gDevTrib", reduction: "gRed"
      }.freeze

      FIELDS = {
        "infCte" => {
          issuer: "emit", sender: "rem", dispatcher: "exped", receiver: "receb", recipient: "dest",
          complementary_info: "compl", service_value: "vPrest", taxes: "imp", payment_links: "pgtoVinc",
          normal: "infCTeNorm", complements: "infCteComp", technical_contact: "infRespTec"
        },
        "ide" => {
          state_code: "cUF", numeric_code: "cCT", cfop: "CFOP", nature_of_operation: "natOp", model: "mod",
          series: "serie", number: "nCT", issued_at: "dhEmi", print_format: "tpImp", emission_type: "tpEmis",
          check_digit: "cDV", environment: "tpAmb", cte_type: "tpCTe", process: "procEmi",
          software_version: "verProc", globalized: "indGlobalizado", sent_city_code: "cMunEnv",
          sent_city: "xMunEnv", sent_state: "UFEnv", modal: "modal", service_type: "tpServ",
          origin_city_code: "cMunIni", origin_city: "xMunIni", origin_state: "UFIni",
          destination_city_code: "cMunFim", destination_city: "xMunFim", destination_state: "UFFim",
          pickup: "retira", pickup_details: "xDetRetira", taker_ie_indicator: "indIEToma",
          contingency_at: "dhCont", contingency_reason: "xJust", government_purchase: "gCompraGov"
        },
        "gCompraGov" => {
          entity: "tpEnteGov", reduction: "pRedutor", operation: "tpOperGov", referenced_dfe: "refDFeAnt"
        },
        "toma3" => {role: "toma"},
        "toma4" => PARTY.merge(role: "toma", address: "enderToma"),
        "emit" => PARTY.merge(
          address: "enderEmit", st_state_registration: "IEST", tax_regime: "CRT",
          suframa: "ISUFEmit", ibs_cbs_regime: "tpRegimeIBSCBS"
        ),
        "rem" => PARTY.merge(address: "enderReme"),
        "exped" => PARTY.merge(address: "enderExped"),
        "receb" => PARTY.merge(address: "enderReceb"),
        "dest" => PARTY.merge(address: "enderDest", suframa: "ISUF"),
        "enderEmit" => ADDRESS, "enderReme" => ADDRESS, "enderExped" => ADDRESS,
        "enderReceb" => ADDRESS, "enderDest" => ADDRESS, "enderToma" => ADDRESS,
        "compl" => {
          additional_feature: "xCaracAd", service_feature: "xCaracSer", issuer_initials: "xEmi",
          flow: "fluxo", delivery: "Entrega", origin_calc: "origCalc", destination_calc: "destCalc",
          notes: "xObs", taxpayer_note: "ObsCont", taxpayer_notes: "ObsCont",
          tax_authority_note: "ObsFisco", tax_authority_notes: "ObsFisco"
        },
        "ObsCont" => {field: "@xCampo", text: "xTexto"},
        "ObsFisco" => {field: "@xCampo", text: "xTexto"},
        "vPrest" => {
          total: "vTPrest", net_total: "vTPrestLiq", receivable: "vRec",
          component: "Comp", components: "Comp"
        },
        "Comp" => {name: "xNome", amount: "vComp"},
        "imp" => {
          total_tax: "vTotTrib", tax_authority_notes: "infAdFisco", difal: "ICMSUFFim",
          ibs_cbs: "IBSCBS", total_dfe: "vTotDFe"
        },
        "ICMS00" => {cst: "CST", base: "vBC", rate: "pICMS", amount: "vICMS"},
        "ICMS20" => {
          cst: "CST", base_reduction: "pRedBC", base: "vBC", rate: "pICMS", amount: "vICMS",
          exempted_amount: "vICMSDeson", benefit_code: "cBenef"
        },
        "ICMS45" => {cst: "CST", exempted_amount: "vICMSDeson", benefit_code: "cBenef"},
        "ICMS60" => {
          cst: "CST", st_retained_base: "vBCSTRet", st_retained_amount: "vICMSSTRet",
          st_retained_rate: "pICMSSTRet", credit: "vCred", exempted_amount: "vICMSDeson",
          benefit_code: "cBenef"
        },
        "ICMS90" => {
          cst: "CST", base_reduction: "pRedBC", base: "vBC", rate: "pICMS", amount: "vICMS",
          credit: "vCred", exempted_amount: "vICMSDeson", benefit_code: "cBenef"
        },
        "ICMSOutraUF" => {
          cst: "CST", base_reduction: "pRedBCOutraUF", base: "vBCOutraUF", rate: "pICMSOutraUF",
          amount: "vICMSOutraUF", exempted_amount: "vICMSDeson", benefit_code: "cBenef"
        },
        "ICMSSN" => {cst: "CST", simples: "indSN"},
        "gICMSPrevistoPagtoAntecip" => {forecast_amount: "vICMSPrevisto"},
        "ICMSUFFim" => {
          base: "vBCUFFim", fcp_rate: "pFCPUFFim", destination_rate: "pICMSUFFim",
          interstate_rate: "pICMSInter", fcp_amount: "vFCPUFFim", destination_amount: "vICMSUFFim",
          origin_amount: "vICMSUFIni"
        },
        "IBSCBS" => {
          cst: "CST", class_code: "cClassTrib", donation: "indDoacao",
          simples: "gTribSN", credit_reversal: "gEstornoCred"
        },
        "gIBSCBS" => {
          base: "vBC", ibs_uf: "gIBSUF", ibs_municipal: "gIBSMun", ibs_amount: "vIBS",
          cbs: "gCBS", regular: "gTribRegular", government_purchase: "gTribCompraGov"
        },
        "gIBSUF" => IBS_CBS_RATE_FIELDS.merge(rate: "pIBSUF", amount: "vIBSUF"),
        "gIBSMun" => IBS_CBS_RATE_FIELDS.merge(rate: "pIBSMun", amount: "vIBSMun"),
        "gCBS" => IBS_CBS_RATE_FIELDS.merge(rate: "pCBS", amount: "vCBS", alc_zfm: "gALCZFMCBS"),
        "gDif" => {rate: "pDif", amount: "vDif"},
        "gDevTrib" => {rate: "pDevTrib", amount: "vDevTrib"},
        "gRed" => {rate: "pRedAliq", effective_rate: "pAliqEfet"},
        "gTribRegular" => {
          cst: "CSTReg", class_code: "cClassTribReg",
          ibs_uf_rate: "pAliqEfetRegIBSUF", ibs_uf_amount: "vTribRegIBSUF",
          ibs_municipal_rate: "pAliqEfetRegIBSMun", ibs_municipal_amount: "vTribRegIBSMun",
          cbs_rate: "pAliqEfetRegCBS", cbs_amount: "vTribRegCBS"
        },
        "gTribCompraGov" => {
          ibs_uf_rate: "pAliqIBSUF", ibs_uf_amount: "vTribIBSUF",
          ibs_municipal_rate: "pAliqIBSMun", ibs_municipal_amount: "vTribIBSMun",
          cbs_rate: "pAliqCBS", cbs_amount: "vTribCBS"
        },
        "gTribSN" => {ibs: "gIBSSN", cbs: "gCBSSN"},
        "gIBSSN" => {rate: "pIBSSN", amount: "vIBSSN"},
        "gCBSSN" => {rate: "pCBSSN", amount: "vCBSSN"},
        "gEstornoCred" => {ibs: "vIBSEstCred", cbs: "vCBSEstCred"},
        "pgto" => {
          number: "@nPag", transaction_id: "@idTransacao", method: "tpMeioPgto",
          receiver_cnpj: "CNPJReceb", psp_cnpj_base: "CNPJBasePSP"
        },
        "infCTeNorm" => {
          cargo: "infCarga", documents: "infDoc", previous_documents: "docAnt",
          billing: "cobr", substitution: "infCteSub", globalized_info: "infGlobalizado",
          linked_service: "infServVinc", new_vehicles: "veicNovos"
        },
        "infCarga" => {
          value: "vCarga", product: "proPred", other_features: "xOutCat",
          measure: "infQ", measures: "infQ", insured_value: "vCargaAverb"
        },
        "infQ" => {unit: "cUnid", kind: "tpMed", quantity: "qCarga"},
        "infDoc" => {
          nf: "infNF", nfe: "infNFe", other_document: "infOutros", dce: "infDCe"
        },
        "infNFe" => {
          key: "chave", pin: "PIN", expected_delivery: "dPrev",
          cargo_unit: "infUnidCarga", transport_unit: "infUnidTransp"
        },
        "infDCe" => {key: "chave"},
        "infOutros" => {
          kind: "tpDoc", description: "descOutros", number: "nDoc", issued_on: "dEmi",
          value: "vDocFisc", expected_delivery: "dPrev"
        },
        "emiDocAnt" => {
          cnpj: "CNPJ", cpf: "CPF", state_registration: "IE", state: "UF", name: "xNome",
          documents: "idDocAnt"
        },
        "idDocAntEle" => {key: "chCTe"},
        "cobr" => {invoice: "fat", installment: "dup", installments: "dup"},
        "fat" => {number: "nFat", original_amount: "vOrig", discount: "vDesc", net_amount: "vLiq"},
        "dup" => {number: "nDup", due_on: "dVenc", amount: "vDup"},
        "infCteSub" => {key: "chCte", change_taker: "indAlteraToma"},
        "infGlobalizado" => {notes: "xObs"},
        "infServVinc" => {multimodal_cte: "infCTeMultimodal"},
        "infCTeMultimodal" => {key: "chCTeMultimodal"},
        "infCteComp" => {key: "chCTe"},
        "infRespTec" => {
          cnpj: "CNPJ", contact: "xContato", email: "email", phone: "fone",
          csrt_id: "idCSRT", csrt_hash: "hashCSRT"
        },
        "rodo" => {rntrc: "RNTRC", collection_order: "occ", collection_orders: "occ"},
        "occ" => {series: "serie", number: "nOcc", issued_on: "dEmi", issuer: "emiOcc"},
        "emiOcc" => {
          cnpj: "CNPJ", internal_code: "cInt", state_registration: "IE", state: "UF", phone: "fone"
        },
        "multimodal" => {cotm: "COTM", negotiable: "indNegociavel", insurance: "seg"}
      }.freeze

      ENUMS = {
        "tpImp" => {portrait: 1, landscape: 2},
        "tpEmis" => {normal: 1, offline: 2, nff: 3, epec: 4, svc_rs: 7, svc_sp: 8},
        "tpCTe" => {normal: 0, complementary: 1, substitution: 3},
        "procEmi" => {own_software: 0, fisco: 3, paa: 4},
        "modal" => {road: "01", air: "02", water: "03", rail: "04", pipeline: "05", multimodal: "06"},
        "tpServ" => {normal: 0, subcontracting: 1, redispatch: 2, intermediate_redispatch: 3, multimodal_linked: 4},
        "retira" => {yes: 0, no: 1},
        "indIEToma" => {contributor: 1, exempt: 2, non_contributor: 9},
        "toma" => {sender: 0, dispatcher: 1, receiver: 2, recipient: 3, other: 4},
        "CRT" => {simples: 1, simples_excess: 2, normal: 3, mei: 4},
        "cUnid" => {m3: "00", kg: "01", ton: "02", unit: "03", liters: "04", mmbtu: "05"},
        "tpDoc" => {declaration: "00", dutoviario: "10", cfe_sat: "59", nfce: "65", other: "99"},
        "tpMeioPgto" => {
          bank_slip: "15", pix: "17", transfer: "18", instant_payment: "20",
          debit_direct: "23", credit_card: "24"
        },
        "tpEnteGov" => {union: 1, state: 2, federal_district: 3, municipality: 4},
        "tpOperGov" => {supply: 1, payment: 2},
        "indNegociavel" => {non_negotiable: 0, negotiable: 1}
      }.freeze

      module_function

      def snake(tag)
        tag.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
      end

      def table_for(tag) = FIELDS[tag] || {}

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
