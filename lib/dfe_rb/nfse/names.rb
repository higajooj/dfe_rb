module DfeRb
  module Nfse
    # The vocabulary of the DPS builder: readable English names for the layout's fields (the
    # XML tag each one maps to), plus friendly symbols for coded values. Every field is also
    # reachable by its official tag ("cTribNac"), or as snake_case ("c_trib_nac"). A name
    # whose tag a layout lacks (`deductions` in NT 009, `base_adjustment` before it) isn't
    # offered by that layout.
    module Names
      PARTY = {
        cnpj: "CNPJ", cpf: "CPF", nif: "NIF", no_nif_reason: "cNaoNIF", caepf: "CAEPF", municipal_registration: "IM",
        name: "xNome", address: "end", phone: "fone", email: "email"
      }.freeze

      ADDRESS = {national: "endNac", foreign: "endExt", street: "xLgr", number: "nro", complement: "xCpl", district: "xBairro"}.freeze

      DOCUMENT = {
        national_dfe: "dFeNacional", other_fiscal_document: "docFiscalOutro", other_document: "docOutro", supplier: "fornec",
        issued_on: "dtEmiDoc", service_date: "dtCompDoc"
      }.freeze

      # Per element tag. "infDPS" is the declaration itself.
      FIELDS = {
        "infDPS" => {
          environment: "tpAmb", issued_at: "dhEmi", software_version: "verAplic", series: "serie", number: "nDPS",
          service_date: "dCompet", issuer_type: "tpEmit", issuer_reason: "cMotivoEmisTI", rejected_key: "chNFSeRej",
          city_code: "cLocEmi", replaces: "subst", provider: "prest", taker: "toma", intermediary: "interm",
          service: "serv", values: "valores", ibs_cbs: "IBSCBS", purpose: "finNFSe"
        },
        "subst" => {key: "chSubstda", reason: "cMotivo", description: "xMotivo"},
        "prest" => PARTY.merge(tax_regime: "regTrib"),
        "toma" => PARTY, "interm" => PARTY,
        "regTrib" => {simples: "opSimpNac", simples_regime: "regApTribSN", special_regime: "regEspTrib"},
        "end" => ADDRESS.merge(zip: "CEP", cib: "cCIB"),
        "endNac" => {city_code: "cMun", zip: "CEP"},
        "endExt" => {country: "cPais", postal_code: "cEndPost", city: "xCidade", region: "xEstProvReg"},
        "serv" => {place: "locPrest", code: "cServ", foreign_trade: "comExt", construction: "obra", event: "atvEvento", additional_info: "infoCompl"},
        "locPrest" => {city_code: "cLocPrestacao", country: "cPaisPrestacao"},
        "cServ" => {national_code: "cTribNac", municipal_code: "cTribMun", nbs: "cNBS", internal_code: "cIntContrib", description: "xDescServ"},
        "infoCompl" => {technical_document: "idDocTec", document_reference: "docRef", order: "xPed", order_items: "gItemPed", notes: "xInfComp"},
        "obra" => {property_registration: "inscImobFisc", code: "cObra", cib: "cCIB", address: "end"},
        "atvEvento" => {name: "xNome", starts_on: "dtIni", ends_on: "dtFim", code: "idAtvEvt", address: "end"},
        "valores" => {
          service: "vServPrest", discounts: "vDescCondIncond", deductions: "vDedRed", base_adjustment: "vAjusteBC",
          taxes: "trib", reimbursements: "gReeRepRes"
        },
        "vServPrest" => {received: "vReceb", amount: "vServ"},
        "vDescCondIncond" => {unconditional_discount: "vDescIncond", conditional_discount: "vDescCond"},
        "vDedRed" => {rate: "pDR", amount: "vDR", documents: "documentos"},
        "vAjusteBC" => {rate: "pAjusteBCISSQN", amount: "vAjusteBCISSQN", documents: "documentos"},
        "docDedRed" => DOCUMENT.merge(kind: "tpDedRed", description: "xDescOutDed", deductible: "vDedutivelRedutivel", amount: "vDeducaoReducao",
          nfse_key: "chNFSe", nfe_key: "chNFe"),
        "docAjusteBC" => DOCUMENT.merge(kind: "tpAjusteBC", description: "xTpAjusteBC", document_total: "vTotDoc", amount: "vAjusteAplic"),
        "dFeNacional" => {kind: "tipoChaveDFe", description: "xTipoChaveDFe", key: "chaveDFe"},
        "fornec" => PARTY,
        "trib" => {
          municipal: "tribMun", federal: "tribFed", approximate_taxes: "totTrib",
          cst: "CST", class_code: "cClassTrib", ibs_cbs: "gIBSCBS"
        },
        "tribMun" => {
          issqn: "tribISSQN", result_country: "cPaisResult", immunity: "tpImunidade", suspension: "exigSusp",
          benefit: "BM", withholding: "tpRetISSQN", iss_rate: "pAliq"
        },
        "exigSusp" => {kind: "tpSusp", process: "nProcesso"},
        "BM" => {number: "nBM", reduction_amount: "vRedBCBM", reduction_rate: "pRedBCBM"},
        "tribFed" => {pis_cofins: "piscofins", social_security_withheld: "vRetCP", irrf_withheld: "vRetIRRF", csll_withheld: "vRetCSLL"},
        "piscofins" => {
          cst: "CST", base: "vBCPisCofins", pis_rate: "pAliqPis", cofins_rate: "pAliqCofins", pis: "vPis", cofins: "vCofins",
          withholding: "tpRetPisCofins"
        },
        "totTrib" => {amounts: "vTotTrib", rates: "pTotTrib", not_informed: "indTotTrib", simples_rate: "pTotTribSN"},
        "vTotTrib" => {federal: "vTotTribFed", state: "vTotTribEst", municipal: "vTotTribMun"},
        "pTotTrib" => {federal: "pTotTribFed", state: "pTotTribEst", municipal: "pTotTribMun"},
        "IBSCBS" => {
          purpose: "finNFSe", final_consumer: "indFinal", operation_indicator: "cIndOp", operation_type: "tpOper",
          referenced: "gRefNFSe", government_entity: "tpEnteGov", recipient_indicator: "indDest", recipient: "dest",
          real_estate: "imovel", movable_goods: "bensMoveis", values: "valores"
        },
        "gRefNFSe" => {key: "refNFSe", keys: "refNFSe"},
        "imovel" => {city_code: "cMun", property_registration: "inscImobFisc", cib: "cCIB", address: "end", rental: "gLocacao", unit: "gUnidImob", units: "gUnidImob"},
        "gUnidImob" => {property_registration: "inscImobFisc", cib: "cCIB", address: "end"},
        "dest" => PARTY,
        "gIBSCBS" => {cst: "CST", class_code: "cClassTrib", presumed_credit: "cCredPres", regular: "gTribRegular", deferral: "gDif"},
        "gTribRegular" => {cst: "CSTReg", class_code: "cClassTribReg"},
        "gDif" => {state: "pDifUF", city: "pDifMun", cbs: "pDifCBS"}
      }.freeze

      ENUMS = {
        "tpEmit" => {provider: 1, taker: 2, intermediary: 3},
        "cMotivoEmisTI" => {import: 1, required_by_law: 2, provider_refused: 3, rejected: 4},
        "cNaoNIF" => {not_informed: 0, exempt: 1, not_required: 2},
        "opSimpNac" => {none: 1, mei: 2, me_epp: 3},
        "regApTribSN" => {simples: 1, federal_by_simples: 2, outside_simples: 3},
        "regEspTrib" => {
          none: 0, cooperative: 1, estimate: 2, municipal_microenterprise: 3, notary: 4, self_employed: 5,
          professional_society: 6, other: 9
        },
        "cMotivo" => {
          simples_exclusion: "01", simples_inclusion: "02", exemption_added: "03", exemption_removed: "04",
          rejected_by_taker: "05", other: "99"
        },
        "tribISSQN" => {taxable: 1, immune: 2, export: 3, not_levied: 4},
        "tpRetISSQN" => {none: 1, taker: 2, intermediary: 3},
        "tpSusp" => {judicial: 1, administrative: 2},
        "tpRetPisCofins" => {
          none: 0, pis_cofins: 1, pis_cofins_not_withheld: 2, pis_cofins_csll: 3, pis_cofins_not_csll: 4, pis: 5,
          cofins: 6, cofins_csll: 7, csll: 8, pis_csll: 9
        },
        "finNFSe" => {regular: 0},
        "tpOper" => {paid_later: 1, payment_after_supply: 2, prepaid: 3, payment_before_supply: 4, simultaneous: 5},
        "tpEnteGov" => {union: 1, state: 2, federal_district: 3, municipality: 4},
        "indDest" => {taker: 0, other: 1}
      }.freeze

      module_function

      # snake_case form of an official tag: "cTribNac" => "c_trib_nac".
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
