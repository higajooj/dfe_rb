module DfeRb
  module Efd
    module Contribuicoes
      # The registers the file can carry, field by field as the Guia Prático da
      # EFD-Contribuições (versão 1.35) lists them, each under its parent: the registers
      # right below a block's opening have none. See Field for the notation.
      #
      # M210 and M610 have the leiaute of the facts from 01/01/2019, with the base's
      # adjustments (fields 05 to 07). NÍVEL of 0500 is written NIVEL, and REC_TOTAL_NRB_PERÍODO of 0900
      # REC_TOTAL_NRB_PERIODO. C100's COD_PART
      # isn't required here: an NFC-e to a consumer not named carries none, as in the
      # EFD ICMS/IPI.
      module Layout
        Register = Data.define(:code, :parent, :fields)

        DEFINITIONS = {
          # Block 0: the company, its regime, establishments and tables.
          "0000" => [nil, %w[REG:C4! COD_VER:N3=! TIPO_ESCRIT:N1! IND_SIT_ESP:N1 NUM_REC_ANTERIOR:C41= DT_INI:D! DT_FIN:D! NOME:C100! CNPJ:N14=!
            UF:C2=! COD_MUN:N7=! SUFRAMA:C9= IND_NAT_PJ:N2= IND_ATIV:N1!]],
          "0001" => [nil, %w[REG:C4! IND_MOV:N1!]],
          "0100" => [nil, %w[REG:C4! NOME:C100! CPF:N11=! CRC:C15! CNPJ:N14= CEP:N8= END:C60 NUM:C COMPL:C60 BAIRRO:C60 FONE:C11 FAX:C11 EMAIL:C
            COD_MUN:N7=]],
          "0110" => [nil, %w[REG:C4! COD_INC_TRIB:N1! IND_APRO_CRED:N1 COD_TIPO_CONT:N1 IND_REG_CUM:N1]],
          "0120" => [nil, %w[REG:C4! MES_REFER:C6=! INF_COMP:C90]],
          "0111" => ["0110", %w[REG:C4! REC_BRU_NCUM_TRIB_MI:N.2! REC_BRU_NCUM_NT_MI:N.2! REC_BRU_NCUM_EXP:N.2! REC_BRU_CUM:N.2! REC_BRU_TOTAL:N.2!]],
          "0140" => [nil, %w[REG:C4! COD_EST:C60 NOME:C100! CNPJ:N14=! UF:C2=! IE:C14 COD_MUN:N7=! IM:C SUFRAMA:C9=]],
          "0150" => ["0140", %w[REG:C4! COD_PART:C60! NOME:C100! COD_PAIS:N5! CNPJ:N14= CPF:N11= IE:C14 COD_MUN:N7= SUFRAMA:C9= END:C60 NUM:C
            COMPL:C60 BAIRRO:C60]],
          "0190" => ["0140", %w[REG:C4! UNID:C6! DESCR:C!]],
          "0200" => ["0140", %w[REG:C4! COD_ITEM:C60! DESCR_ITEM:C! COD_BARRA:C COD_ANT_ITEM:C60 UNID_INV:C6 TIPO_ITEM:N2=! COD_NCM:C8 EX_IPI:C3
            COD_GEN:N2= COD_LST:N4 ALIQ_ICMS:N6.2]],
          "0500" => [nil, %w[REG:C4! DT_ALT:D! COD_NAT_CC:C2=! IND_CTA:C1=! NIVEL:N5! COD_CTA:C255! NOME_CTA:C60! COD_CTA_REF:C60 CNPJ_EST:N14=]],
          "0900" => [nil, %w[REG:C4! REC_TOTAL_BLOCO_A:N.2! REC_NRB_BLOCO_A:N.2 REC_TOTAL_BLOCO_C:N.2! REC_NRB_BLOCO_C:N.2 REC_TOTAL_BLOCO_D:N.2!
            REC_NRB_BLOCO_D:N.2 REC_TOTAL_BLOCO_F:N.2! REC_NRB_BLOCO_F:N.2 REC_TOTAL_BLOCO_I:N.2! REC_NRB_BLOCO_I:N.2 REC_TOTAL_BLOCO_1:N.2!
            REC_NRB_BLOCO_1:N.2 REC_TOTAL_PERIODO:N.2! REC_TOTAL_NRB_PERIODO:N.2]],
          "0990" => [nil, %w[REG:C4! QTD_LIN_0:N!]],
          # Block A: services (ISS).
          "A001" => [nil, %w[REG:C4! IND_MOV:C1!]],
          "A990" => [nil, %w[REG:C4! QTD_LIN_A:N!]],
          # Block C: goods (ICMS/IPI).
          "C001" => [nil, %w[REG:C4! IND_MOV:C1!]],
          "C010" => [nil, %w[REG:C4! CNPJ:N14=! IND_ESCRI:C1=]],
          "C100" => ["C010", %w[REG:C4! IND_OPER:C1=! IND_EMIT:C1=! COD_PART:C60 COD_MOD:C2=! COD_SIT:N2=! SER:C3 NUM_DOC:N9! CHV_NFE:N44= DT_DOC:D!
            DT_E_S:D VL_DOC:N.2! IND_PGTO:C1=! VL_DESC:N.2 VL_ABAT_NT:N.2 VL_MERC:N.2 IND_FRT:C1=! VL_FRT:N.2 VL_SEG:N.2 VL_OUT_DA:N.2 VL_BC_ICMS:N.2
            VL_ICMS:N.2 VL_BC_ICMS_ST:N.2 VL_ICMS_ST:N.2 VL_IPI:N.2 VL_PIS:N.2 VL_COFINS:N.2 VL_PIS_ST:N.2 VL_COFINS_ST:N.2]],
          "C170" => ["C100", %w[REG:C4! NUM_ITEM:N3! COD_ITEM:C60! DESCR_COMPL:C QTD:N.5 UNID:C6 VL_ITEM:N.2! VL_DESC:N.2 IND_MOV:C1 CST_ICMS:N3=
            CFOP:N4=! COD_NAT:C10 VL_BC_ICMS:N.2 ALIQ_ICMS:N6.2 VL_ICMS:N.2 VL_BC_ICMS_ST:N.2 ALIQ_ST:N6.2 VL_ICMS_ST:N.2 IND_APUR:C1= CST_IPI:C2=
            COD_ENQ:C3= VL_BC_IPI:N.2 ALIQ_IPI:N6.2 VL_IPI:N.2 CST_PIS:N2=! VL_BC_PIS:N.2 ALIQ_PIS:N8.4 QUANT_BC_PIS:N.3 ALIQ_PIS_QUANT:N.4
            VL_PIS:N.2 CST_COFINS:N2=! VL_BC_COFINS:N.2 ALIQ_COFINS:N8.4 QUANT_BC_COFINS:N.3 ALIQ_COFINS_QUANT:N.4 VL_COFINS:N.2 COD_CTA:C255]],
          "C175" => ["C100", %w[REG:C4! CFOP:N4=! VL_OPR:N.2! VL_DESC:N.2 CST_PIS:N2=! VL_BC_PIS:N.2 ALIQ_PIS:N8.4 QUANT_BC_PIS:N.3 ALIQ_PIS_QUANT:N.4
            VL_PIS:N.2 CST_COFINS:N2=! VL_BC_COFINS:N.2 ALIQ_COFINS:N8.4 QUANT_BC_COFINS:N.3 ALIQ_COFINS_QUANT:N.4 VL_COFINS:N.2 COD_CTA:C255
            INFO_COMPL:C]],
          "C990" => [nil, %w[REG:C4! QTD_LIN_C:N!]],
          # Block D: transport and communication services.
          "D001" => [nil, %w[REG:C4! IND_MOV:C1!]],
          "D990" => [nil, %w[REG:C4! QTD_LIN_D:N!]],
          # Block F: other documents and operations.
          "F001" => [nil, %w[REG:C4! IND_MOV:C1!]],
          "F990" => [nil, %w[REG:C4! QTD_LIN_F:N!]],
          # Block I: financial institutions.
          "I001" => [nil, %w[REG:C4! IND_MOV:C1!]],
          "I990" => [nil, %w[REG:C4! QTD_LIN_I:N!]],
          # Block M: the apuração of the contributions and credits.
          "M001" => [nil, %w[REG:C4! IND_MOV:C1!]],
          "M100" => [nil, %w[REG:C4! COD_CRED:C3=! IND_CRED_ORI:N1! VL_BC_PIS:N.2 ALIQ_PIS:N8.4 QUANT_BC_PIS:N.3 ALIQ_PIS_QUANT:N.4 VL_CRED:N.2!
            VL_AJUS_ACRES:N.2! VL_AJUS_REDUC:N.2! VL_CRED_DIF:N.2! VL_CRED_DISP:N.2! IND_DESC_CRED:C1=! VL_CRED_DESC:N.2 SLD_CRED:N.2!]],
          "M105" => ["M100", %w[REG:C4! NAT_BC_CRED:C2=! CST_PIS:N2=! VL_BC_PIS_TOT:N.2 VL_BC_PIS_CUM:N.2 VL_BC_PIS_NC:N.2 VL_BC_PIS:N.2
            QUANT_BC_PIS_TOT:N.3 QUANT_BC_PIS:N.3 DESC_CRED:C60]],
          "M110" => ["M100", %w[REG:C4! IND_AJ:C1=! VL_AJ:N.2! COD_AJ:C2=! NUM_DOC:C DESCR_AJ:C DT_REF:D]],
          "M200" => [nil, %w[REG:C4! VL_TOT_CONT_NC_PER:N.2! VL_TOT_CRED_DESC:N.2! VL_TOT_CRED_DESC_ANT:N.2! VL_TOT_CONT_NC_DEV:N.2! VL_RET_NC:N.2!
            VL_OUT_DED_NC:N.2! VL_CONT_NC_REC:N.2! VL_TOT_CONT_CUM_PER:N.2! VL_RET_CUM:N.2! VL_OUT_DED_CUM:N.2! VL_CONT_CUM_REC:N.2!
            VL_TOT_CONT_REC:N.2!]],
          "M205" => ["M200", %w[REG:C4! NUM_CAMPO:C2=! COD_REC:C6=! VL_DEBITO:N.2!]],
          "M210" => ["M200", %w[REG:C4! COD_CONT:C2=! VL_REC_BRT:N.2! VL_BC_CONT:N.2! VL_AJUS_ACRES_BC_PIS:N.2! VL_AJUS_REDUC_BC_PIS:N.2!
            VL_BC_CONT_AJUS:N.2! ALIQ_PIS:N8.4 QUANT_BC_PIS:N.3 ALIQ_PIS_QUANT:N.4 VL_CONT_APUR:N.2! VL_AJUS_ACRES:N.2! VL_AJUS_REDUC:N.2!
            VL_CONT_DIFER:N.2 VL_CONT_DIFER_ANT:N.2 VL_CONT_PER:N.2!]],
          "M215" => ["M210", %w[REG:C4! IND_AJ_BC:C1=! VL_AJ_BC:N.2! COD_AJ_BC:C2=! NUM_DOC:C DESCR_AJ_BC:C DT_REF:D COD_CTA:C255 CNPJ:N14=! INFO_COMPL:C]],
          "M220" => ["M210", %w[REG:C4! IND_AJ:C1=! VL_AJ:N.2! COD_AJ:C2=! NUM_DOC:C DESCR_AJ:C DT_REF:D]],
          "M400" => [nil, %w[REG:C4! CST_PIS:C2=! VL_TOT_REC:N.2! COD_CTA:C255 DESC_COMPL:C]],
          "M410" => ["M400", %w[REG:C4! NAT_REC:C3=! VL_REC:N.2! COD_CTA:C255 DESC_COMPL:C]],
          "M500" => [nil, %w[REG:C4! COD_CRED:C3=! IND_CRED_ORI:N1! VL_BC_COFINS:N.2 ALIQ_COFINS:N8.4 QUANT_BC_COFINS:N.3 ALIQ_COFINS_QUANT:N.4
            VL_CRED:N.2! VL_AJUS_ACRES:N.2! VL_AJUS_REDUC:N.2! VL_CRED_DIFER:N.2! VL_CRED_DISP:N.2! IND_DESC_CRED:C1=! VL_CRED_DESC:N.2 SLD_CRED:N.2!]],
          "M505" => ["M500", %w[REG:C4! NAT_BC_CRED:C2=! CST_COFINS:N2=! VL_BC_COFINS_TOT:N.2 VL_BC_COFINS_CUM:N.2 VL_BC_COFINS_NC:N.2 VL_BC_COFINS:N.2
            QUANT_BC_COFINS_TOT:N.3 QUANT_BC_COFINS:N.3 DESC_CRED:C60]],
          "M510" => ["M500", %w[REG:C4! IND_AJ:C1=! VL_AJ:N.2! COD_AJ:C2=! NUM_DOC:C DESCR_AJ:C DT_REF:D]],
          "M600" => [nil, %w[REG:C4! VL_TOT_CONT_NC_PER:N.2! VL_TOT_CRED_DESC:N.2! VL_TOT_CRED_DESC_ANT:N.2! VL_TOT_CONT_NC_DEV:N.2! VL_RET_NC:N.2!
            VL_OUT_DED_NC:N.2! VL_CONT_NC_REC:N.2! VL_TOT_CONT_CUM_PER:N.2! VL_RET_CUM:N.2! VL_OUT_DED_CUM:N.2! VL_CONT_CUM_REC:N.2!
            VL_TOT_CONT_REC:N.2!]],
          "M605" => ["M600", %w[REG:C4! NUM_CAMPO:C2=! COD_REC:C6=! VL_DEBITO:N.2!]],
          "M610" => ["M600", %w[REG:C4! COD_CONT:C2=! VL_REC_BRT:N.2! VL_BC_CONT:N.2! VL_AJUS_ACRES_BC_COFINS:N.2! VL_AJUS_REDUC_BC_COFINS:N.2!
            VL_BC_CONT_AJUS:N.2! ALIQ_COFINS:N8.4 QUANT_BC_COFINS:N.3 ALIQ_COFINS_QUANT:N.4 VL_CONT_APUR:N.2! VL_AJUS_ACRES:N.2! VL_AJUS_REDUC:N.2!
            VL_CONT_DIFER:N.2 VL_CONT_DIFER_ANT:N.2 VL_CONT_PER:N.2!]],
          "M615" => ["M610", %w[REG:C4! IND_AJ_BC:C1=! VL_AJ_BC:N.2! COD_AJ_BC:C2=! NUM_DOC:C DESCR_AJ_BC:C DT_REF:D COD_CTA:C255 CNPJ:N14=! INFO_COMPL:C]],
          "M620" => ["M610", %w[REG:C4! IND_AJ:C1=! VL_AJ:N.2! COD_AJ:C2=! NUM_DOC:C DESCR_AJ:C DT_REF:D]],
          "M800" => [nil, %w[REG:C4! CST_COFINS:C2=! VL_TOT_REC:N.2! COD_CTA:C255 DESC_COMPL:C]],
          "M810" => ["M800", %w[REG:C4! NAT_REC:C3=! VL_REC:N.2! COD_CTA:C255 DESC_COMPL:C]],
          "M990" => [nil, %w[REG:C4! QTD_LIN_M:N!]],
          # Block P: the contribution on gross revenue (CPRB).
          "P001" => [nil, %w[REG:C4! IND_MOV:C1!]],
          "P990" => [nil, %w[REG:C4! QTD_LIN_P:N!]],
          # Block 1: the credits carried from month to month.
          "1001" => [nil, %w[REG:C4! IND_MOV:N1!]],
          "1100" => [nil, %w[REG:C4! PER_APU_CRED:N6=! ORIG_CRED:N2=! CNPJ_SUC:N14= COD_CRED:N3=! VL_CRED_APU:N.2! VL_CRED_EXT_APU:N.2 VL_TOT_CRED_APU:N.2!
            VL_CRED_DESC_PA_ANT:N.2! VL_CRED_PER_PA_ANT:N.2 VL_CRED_DCOMP_PA_ANT:N.2 SD_CRED_DISP_EFD:N.2! VL_CRED_DESC_EFD:N.2 VL_CRED_PER_EFD:N.2
            VL_CRED_DCOMP_EFD:N.2 VL_CRED_TRANS:N.2 VL_CRED_OUT:N.2 SLD_CRED_FIM:N.2]],
          "1500" => [nil, %w[REG:C4! PER_APU_CRED:N6=! ORIG_CRED:N2=! CNPJ_SUC:N14= COD_CRED:N3=! VL_CRED_APU:N.2! VL_CRED_EXT_APU:N.2 VL_TOT_CRED_APU:N.2!
            VL_CRED_DESC_PA_ANT:N.2! VL_CRED_PER_PA_ANT:N.2 VL_CRED_DCOMP_PA_ANT:N.2 SD_CRED_DISP_EFD:N.2! VL_CRED_DESC_EFD:N.2 VL_CRED_PER_EFD:N.2
            VL_CRED_DCOMP_EFD:N.2 VL_CRED_TRANS:N.2 VL_CRED_OUT:N.2 SLD_CRED_FIM:N.2]],
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
