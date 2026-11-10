module DfeRb
  module Efd
    module IcmsIpi
      # The registers the file can carry, field by field as the Guia Prático da EFD
      # ICMS/IPI lists them (Ato COTEPE/ICMS 44/2018), each under its parent: the
      # registers right below a block's opening have none. See Field for the notation.
      #
      # Field names are the guide's, with two of C170 told apart (ALIQ_PIS_QUANT and
      # ALIQ_COFINS_QUANT, the rates in reais) and the cedillas of E210 and E310 dropped.
      module Layout
        Register = Data.define(:code, :parent, :fields)

        DEFINITIONS = {
          # Block 0: the informant and its tables.
          "0000" => [nil, %w[REG:C4! COD_VER:N3=! COD_FIN:N1! DT_INI:D! DT_FIN:D! NOME:C100! CNPJ:N14= CPF:N11= UF:C2=! IE:C14! COD_MUN:N7=!
            IM:C SUFRAMA:C9= IND_PERFIL:C1! IND_ATIV:N1!]],
          "0001" => [nil, %w[REG:C4! IND_MOV:N1!]],
          "0005" => [nil, %w[REG:C4! FANTASIA:C60! CEP:N8=! END:C60! NUM:C10 COMPL:C60 BAIRRO:C60! FONE:C11 FAX:C11 EMAIL:C]],
          "0100" => [nil, %w[REG:C4! NOME:C100! CPF:N11=! CRC:C15! CNPJ:N14= CEP:N8= END:C60 NUM:C10 COMPL:C60 BAIRRO:C60 FONE:C11 FAX:C11
            EMAIL:C! COD_MUN:N7=!]],
          "0150" => [nil, %w[REG:C4! COD_PART:C60! NOME:C100! COD_PAIS:N5! CNPJ:N14= CPF:N11= IE:C14 COD_MUN:N7= SUFRAMA:C9= END:C60! NUM:C10
            COMPL:C60 BAIRRO:C60]],
          "0190" => [nil, %w[REG:C4! UNID:C6! DESCR:C!]],
          "0200" => [nil, %w[REG:C4! COD_ITEM:C60! DESCR_ITEM:C! COD_BARRA:C COD_ANT_ITEM:C60 UNID_INV:C6! TIPO_ITEM:N2=! COD_NCM:C8= EX_IPI:C3
            COD_GEN:N2= COD_LST:C5 ALIQ_ICMS:N6.2 CEST:N7=]],
          "0220" => ["0200", %w[REG:C4! UNID_CONV:C6! FAT_CONV:N.6! COD_BARRA:C]],
          "0400" => [nil, %w[REG:C4! COD_NAT:C10! DESCR_NAT:C!]],
          "0450" => [nil, %w[REG:C4! COD_INF:C6! TXT:C!]],
          "0460" => [nil, %w[REG:C4! COD_OBS:C6! TXT:C!]],
          "0990" => [nil, %w[REG:C4! QTD_LIN_0:N!]],
          # Block B: the ISS of the Distrito Federal; elsewhere, opened and closed empty.
          "B001" => [nil, %w[REG:C4! IND_DAD:N1!]],
          "B990" => [nil, %w[REG:C4! QTD_LIN_B:N!]],
          # Block C: goods (ICMS/IPI).
          "C001" => [nil, %w[REG:C4! IND_MOV:C1!]],
          "C100" => [nil, %w[REG:C4! IND_OPER:C1=! IND_EMIT:C1=! COD_PART:C60 COD_MOD:C2=! COD_SIT:N2=! SER:C3 NUM_DOC:N9! CHV_NFE:N44= DT_DOC:D
            DT_E_S:D VL_DOC:N.2 IND_PGTO:C1= VL_DESC:N.2 VL_ABAT_NT:N.2 VL_MERC:N.2 IND_FRT:C1= VL_FRT:N.2 VL_SEG:N.2 VL_OUT_DA:N.2 VL_BC_ICMS:N.2
            VL_ICMS:N.2 VL_BC_ICMS_ST:N.2 VL_ICMS_ST:N.2 VL_IPI:N.2 VL_PIS:N.2 VL_COFINS:N.2 VL_PIS_ST:N.2 VL_COFINS_ST:N.2]],
          "C101" => ["C100", %w[REG:C4! VL_FCP_UF_DEST:N.2! VL_ICMS_UF_DEST:N.2! VL_ICMS_UF_REM:N.2!]],
          "C170" => ["C100", %w[REG:C4! NUM_ITEM:N3! COD_ITEM:C60! DESCR_COMPL:C QTD:N.5! UNID:C6! VL_ITEM:N.2! VL_DESC:N.2 IND_MOV:C1=! CST_ICMS:N3=!
            CFOP:N4=! COD_NAT:C10 VL_BC_ICMS:N.2 ALIQ_ICMS:N6.2 VL_ICMS:N.2 VL_BC_ICMS_ST:N.2 ALIQ_ST:N.2 VL_ICMS_ST:N.2 IND_APUR:C1= CST_IPI:C2=
            COD_ENQ:C3= VL_BC_IPI:N.2 ALIQ_IPI:N6.2 VL_IPI:N.2 CST_PIS:N2= VL_BC_PIS:N.2 ALIQ_PIS:N8.4 QUANT_BC_PIS:N.3 ALIQ_PIS_QUANT:N.4
            VL_PIS:N.2 CST_COFINS:N2= VL_BC_COFINS:N.2 ALIQ_COFINS:N8.4 QUANT_BC_COFINS:N.3 ALIQ_COFINS_QUANT:N.4 VL_COFINS:N.2 COD_CTA:C
            VL_ABAT_NT:N.2]],
          "C190" => ["C100", %w[REG:C4! CST_ICMS:N3=! CFOP:N4=! ALIQ_ICMS:N6.2 VL_OPR:N.2! VL_BC_ICMS:N.2! VL_ICMS:N.2! VL_BC_ICMS_ST:N.2!
            VL_ICMS_ST:N.2! VL_RED_BC:N.2! VL_IPI:N.2! COD_OBS:C6]],
          "C195" => ["C100", %w[REG:C4! COD_OBS:C6! TXT_COMPL:C]],
          "C197" => ["C195", %w[REG:C4! COD_AJ:C10=! DESCR_COMPL_AJ:C COD_ITEM:C60 VL_BC_ICMS:N.2 ALIQ_ICMS:N6.2 VL_ICMS:N.2 VL_OUTROS:N.2]],
          "C990" => [nil, %w[REG:C4! QTD_LIN_C:N!]],
          # Block D: services (ICMS).
          "D001" => [nil, %w[REG:C4! IND_MOV:C1!]],
          "D990" => [nil, %w[REG:C4! QTD_LIN_D:N!]],
          # Block E: the apurações.
          "E001" => [nil, %w[REG:C4! IND_MOV:C1!]],
          "E100" => [nil, %w[REG:C4! DT_INI:D! DT_FIN:D!]],
          "E110" => ["E100", %w[REG:C4! VL_TOT_DEBITOS:N.2! VL_AJ_DEBITOS:N.2! VL_TOT_AJ_DEBITOS:N.2! VL_ESTORNOS_CRED:N.2! VL_TOT_CREDITOS:N.2!
            VL_AJ_CREDITOS:N.2! VL_TOT_AJ_CREDITOS:N.2! VL_ESTORNOS_DEB:N.2! VL_SLD_CREDOR_ANT:N.2! VL_SLD_APURADO:N.2! VL_TOT_DED:N.2!
            VL_ICMS_RECOLHER:N.2! VL_SLD_CREDOR_TRANSPORTAR:N.2! DEB_ESP:N.2!]],
          "E111" => ["E110", %w[REG:C4! COD_AJ_APUR:C8=! DESCR_COMPL_AJ:C VL_AJ_APUR:N.2!]],
          "E116" => ["E110", %w[REG:C4! COD_OR:C3=! VL_OR:N.2! DT_VCTO:D! COD_REC:C! NUM_PROC:C60 IND_PROC:C1= PROC:C TXT_COMPL:C MES_REF:N6=!]],
          "E200" => [nil, %w[REG:C4! UF:C2=! DT_INI:D! DT_FIN:D!]],
          "E210" => ["E200", %w[REG:C4! IND_MOV_ST:C1! VL_SLD_CRED_ANT_ST:N.2! VL_DEVOL_ST:N.2! VL_RESSARC_ST:N.2! VL_OUT_CRED_ST:N.2!
            VL_AJ_CREDITOS_ST:N.2! VL_RETENCAO_ST:N.2! VL_OUT_DEB_ST:N.2! VL_AJ_DEBITOS_ST:N.2! VL_SLD_DEV_ANT_ST:N.2! VL_DEDUCOES_ST:N.2!
            VL_ICMS_RECOL_ST:N.2! VL_SLD_CRED_ST_TRANSPORTAR:N.2! DEB_ESP_ST:N.2!]],
          "E250" => ["E210", %w[REG:C4! COD_OR:C3=! VL_OR:N.2! DT_VCTO:D! COD_REC:C! NUM_PROC:C60 IND_PROC:C1= PROC:C TXT_COMPL:C MES_REF:N6=!]],
          "E300" => [nil, %w[REG:C4! UF:C2=! DT_INI:D! DT_FIN:D!]],
          "E310" => ["E300", %w[REG:C4! IND_MOV_FCP_DIFAL:C1! VL_SLD_CRED_ANT_DIFAL:N.2! VL_TOT_DEBITOS_DIFAL:N.2! VL_OUT_DEB_DIFAL:N.2!
            VL_TOT_CREDITOS_DIFAL:N.2! VL_OUT_CRED_DIFAL:N.2! VL_SLD_DEV_ANT_DIFAL:N.2! VL_DEDUCOES_DIFAL:N.2! VL_RECOL_DIFAL:N.2!
            VL_SLD_CRED_TRANSPORTAR_DIFAL:N.2! DEB_ESP_DIFAL:N.2! VL_SLD_CRED_ANT_FCP:N.2! VL_TOT_DEB_FCP:N.2! VL_OUT_DEB_FCP:N.2!
            VL_TOT_CRED_FCP:N.2! VL_OUT_CRED_FCP:N.2! VL_SLD_DEV_ANT_FCP:N.2! VL_DEDUCOES_FCP:N.2! VL_RECOL_FCP:N.2!
            VL_SLD_CRED_TRANSPORTAR_FCP:N.2! DEB_ESP_FCP:N.2!]],
          "E316" => ["E310", %w[REG:C4! COD_OR:C3=! VL_OR:N.2! DT_VCTO:D! COD_REC:C! NUM_PROC:C60 IND_PROC:C1= PROC:C TXT_COMPL:C MES_REF:N6=!]],
          "E500" => [nil, %w[REG:C4! IND_APUR:C1=! DT_INI:D! DT_FIN:D!]],
          "E510" => ["E500", %w[REG:C4! CFOP:N4=! CST_IPI:C2=! VL_CONT_IPI:N.2! VL_BC_IPI:N.2! VL_IPI:N.2!]],
          "E520" => ["E500", %w[REG:C4! VL_SD_ANT_IPI:N.2! VL_DEB_IPI:N.2! VL_CRED_IPI:N.2! VL_OD_IPI:N.2! VL_OC_IPI:N.2! VL_SC_IPI:N.2!
            VL_SD_IPI:N.2!]],
          "E990" => [nil, %w[REG:C4! QTD_LIN_E:N!]],
          # Block G: CIAP (fixed assets' ICMS credit).
          "G001" => [nil, %w[REG:C4! IND_MOV:C1!]],
          "G990" => [nil, %w[REG:C4! QTD_LIN_G:N!]],
          # Block H: the inventory.
          "H001" => [nil, %w[REG:C4! IND_MOV:C1!]],
          "H005" => [nil, %w[REG:C4! DT_INV:D! VL_INV:N.2! MOT_INV:C2=!]],
          "H010" => ["H005", %w[REG:C4! COD_ITEM:C60! UNID:C6! QTD:N.3! VL_UNIT:N.6! VL_ITEM:N.2! IND_PROP:C1=! COD_PART:C60 TXT_COMPL:C COD_CTA:C
            VL_ITEM_IR:N.2]],
          "H020" => ["H010", %w[REG:C4! CST_ICMS:N3=! BC_ICMS:N.2! VL_ICMS:N.2!]],
          "H990" => [nil, %w[REG:C4! QTD_LIN_H:N!]],
          # Block K: production and stock control, for industry and wholesale.
          "K001" => [nil, %w[REG:C4! IND_MOV:C1!]],
          "K990" => [nil, %w[REG:C4! QTD_LIN_K:N!]],
          # Block 1: other information.
          "1001" => [nil, %w[REG:C4! IND_MOV:N1!]],
          "1010" => [nil, %w[REG:C4! IND_EXP:C1=! IND_CCRF:C1=! IND_COMB:C1=! IND_USINA:C1=! IND_VA:C1=! IND_EE:C1=! IND_CART:C1=! IND_FORM:C1=!
            IND_AER:C1=! IND_GIAF1:C1=! IND_GIAF3:C1=! IND_GIAF4:C1=! IND_REST_RESSARC_COMPL_ICMS:C1=!]],
          "1990" => [nil, %w[REG:C4! QTD_LIN_1:N!]],
          # Block 9: the file's control.
          "9001" => [nil, %w[REG:C4! IND_MOV:N1!]],
          "9900" => [nil, %w[REG:C4! REG_BLC:C4! QTD_REG_BLC:N!]],
          "9990" => [nil, %w[REG:C4! QTD_LIN_9:N!]],
          "9999" => [nil, %w[REG:C4! QTD_LIN:N!]]
        }.freeze

        REGISTERS = DEFINITIONS.to_h do |code, (parent, fields)|
          [code, Register.new(code:, parent:, fields: fields.map { |f| Field.parse(f) }.freeze)]
        end.freeze

        module_function

        def fetch(code)
          REGISTERS.fetch(code) { raise ArgumentError, "unknown register #{code}" }
        end
      end
    end
  end
end
