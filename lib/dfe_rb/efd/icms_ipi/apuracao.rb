module DfeRb
  module Efd
    module IcmsIpi
      # The apurações of Block E, worked out as the Guia Prático's validations state them:
      # the ICMS's own (E110), the ST's per state (E210), the DIFAL's and FCP's per state
      # (E310) and the IPI's (E520). Each returns the record's values.
      #
      # Adjustments (E111) are {code:, amount:}, their code COD_AJ_APUR from the state's
      # table 5.1.1: the state, then "0" for the ICMS's own apuração, then what the
      # adjustment does (0 other debits, 1 credits reversed, 2 other credits, 3 debits
      # reversed, 4 deductions, 5 special debits), then four digits.
      module Apuracao
        ZERO = BigDecimal(0)
        ADJUSTMENT_KINDS = {"0" => :other_debits, "1" => :reversed_credits, "2" => :other_credits, "3" => :reversed_debits,
                            "4" => :deductions, "5" => :special_debits}.freeze

        module_function

        # E110. debits and credits are the ICMS of the period's documents (C190 going out
        # and coming in); the document_* values are those of their adjustments (C197).
        def e110(debits:, credits:, previous_credit: ZERO, adjustments: [], document_debits: ZERO, document_credits: ZERO,
          document_deductions: ZERO, document_special_debits: ZERO)
          kinds = adjustment_totals(adjustments, "0")
          raise ArgumentError, "unknown adjustment code #{kinds[:unknown].join(", ")}" if kinds[:unknown].any?

          deductions = d(document_deductions) + kinds[:deductions]
          balance = d(debits) + d(document_debits) + kinds[:other_debits] + kinds[:reversed_credits] -
            (d(credits) + d(document_credits) + kinds[:other_credits] + kinds[:reversed_debits] + d(previous_credit))
          due = [balance, ZERO].max
          payable = due - deductions
          carried = [-balance, ZERO].max + [-payable, ZERO].max
          {
            vl_tot_debitos: d(debits), vl_aj_debitos: d(document_debits), vl_tot_aj_debitos: kinds[:other_debits],
            vl_estornos_cred: kinds[:reversed_credits], vl_tot_creditos: d(credits), vl_aj_creditos: d(document_credits),
            vl_tot_aj_creditos: kinds[:other_credits], vl_estornos_deb: kinds[:reversed_debits], vl_sld_credor_ant: d(previous_credit),
            vl_sld_apurado: due, vl_tot_ded: deductions, vl_icms_recolher: [payable, ZERO].max, vl_sld_credor_transportar: carried,
            deb_esp: d(document_special_debits) + kinds[:special_debits]
          }
        end

        # E210 of a state. retention is the ICMS-ST charged going out (C190 of CFOPs 5 and 6
        # to the state), returns the ST of goods given back (VL_DEVOL_ST).
        def e210(retention: ZERO, returns: ZERO, refunds: ZERO, previous_credit: ZERO, other_credits: ZERO, document_credits: ZERO,
          other_debits: ZERO, document_debits: ZERO, deductions: ZERO, special_debits: ZERO, moved: nil)
          credits = d(previous_credit) + d(returns) + d(refunds) + d(other_credits) + d(document_credits)
          debits = d(retention) + d(other_debits) + d(document_debits)
          due = [debits - credits, ZERO].max
          moved = [retention, returns, refunds].any? { |v| d(v).positive? } if moved.nil?
          {
            ind_mov_st: moved ? "1" : "0", vl_sld_cred_ant_st: d(previous_credit), vl_devol_st: d(returns), vl_ressarc_st: d(refunds),
            vl_out_cred_st: d(other_credits), vl_aj_creditos_st: d(document_credits), vl_retencao_st: d(retention), vl_out_deb_st: d(other_debits),
            vl_aj_debitos_st: d(document_debits), vl_sld_dev_ant_st: due, vl_deducoes_st: d(deductions),
            vl_icms_recol_st: [due - d(deductions), ZERO].max, vl_sld_cred_st_transportar: [credits + d(deductions) - debits, ZERO].max,
            deb_esp_st: d(special_debits)
          }
        end

        # E310 of a state: the DIFAL and the FCP, each {debits:, credits:, previous_credit:,
        # other_debits:, other_credits:, deductions:, special_debits:}, debits being the
        # C101 of the sales to the state.
        def e310(difal: {}, fcp: {})
          a = side(difal)
          f = side(fcp)
          moved = [difal, fcp].any? { |given| d(given[:debits]).positive? || d(given[:credits]).positive? }
          {
            ind_mov_fcp_difal: moved ? "1" : "0",
            vl_sld_cred_ant_difal: a[:previous_credit], vl_tot_debitos_difal: a[:debits], vl_out_deb_difal: a[:other_debits],
            vl_tot_creditos_difal: a[:credits], vl_out_cred_difal: a[:other_credits], vl_sld_dev_ant_difal: a[:due],
            vl_deducoes_difal: a[:deductions], vl_recol_difal: a[:payable], vl_sld_cred_transportar_difal: a[:carried],
            deb_esp_difal: a[:special_debits],
            vl_sld_cred_ant_fcp: f[:previous_credit], vl_tot_deb_fcp: f[:debits], vl_out_deb_fcp: f[:other_debits],
            vl_tot_cred_fcp: f[:credits], vl_out_cred_fcp: f[:other_credits], vl_sld_dev_ant_fcp: f[:due], vl_deducoes_fcp: f[:deductions],
            vl_recol_fcp: f[:payable], vl_sld_cred_transportar_fcp: f[:carried], deb_esp_fcp: f[:special_debits]
          }
        end

        # E520: the IPI's debits (going out) and credits (coming in).
        def e520(debits:, credits:, previous_balance: ZERO, other_debits: ZERO, other_credits: ZERO)
          balance = d(debits) + d(other_debits) - (d(previous_balance) + d(credits) + d(other_credits))
          {
            vl_sd_ant_ipi: d(previous_balance), vl_deb_ipi: d(debits), vl_cred_ipi: d(credits), vl_od_ipi: d(other_debits),
            vl_oc_ipi: d(other_credits), vl_sc_ipi: [-balance, ZERO].max, vl_sd_ipi: [balance, ZERO].max
          }
        end

        # The adjustments of an apuração (third character of the code) summed by kind.
        def adjustment_totals(adjustments, apuracao)
          totals = ADJUSTMENT_KINDS.values.to_h { |k| [k, ZERO] }
          totals[:unknown] = []
          adjustments.each do |adjustment|
            code = adjustment[:code].to_s
            kind = ADJUSTMENT_KINDS[code[3]] if code.length == 8 && code[2] == apuracao
            kind ? totals[kind] += d(adjustment[:amount]) : totals[:unknown] << code
          end
          totals
        end

        def side(given)
          values = %i[debits credits previous_credit other_debits other_credits deductions special_debits].to_h { |k| [k, d(given[k])] }
          balance = values[:debits] + values[:other_debits] - (values[:previous_credit] + values[:credits] + values[:other_credits])
          due = [balance, ZERO].max
          values.merge(due:, payable: [due - values[:deductions], ZERO].max,
            carried: [-balance, ZERO].max + [values[:deductions] - due, ZERO].max)
        end

        def d(value) = BigDecimal((value || 0).to_s).round(2)
      end
    end
  end
end
