require "bigdecimal"

module DfeRb
  module Nfe
    # The per-item tax values whose result the validation rules fix: products of a base and
    # a rate (vICMS, vFCP, vPIS, vIBSUF...), the DIFAL split, the IBS/CBS base and effective
    # rates. `call` fills whatever an item leaves out; the `expected_*` functions give the
    # value SEFAZ recomputes, for the Validator to compare with what was given.
    #
    # Inputs are never guessed: a value is derived only when everything it depends on is
    # present, and anything given explicitly is kept.
    module Calculator
      # What an item's taxes depend on beyond the item: the states of the operation, idDest,
      # the issue year and the government purchase reducer (ide/gCompraGov/pRedutor).
      Context = Struct.new(:origin_state, :destination_state, :destination, :year, :purchase_reduction)

      HUNDRED = BigDecimal(100)
      ICMS_RATED = %w[ICMS00 ICMS10 ICMS20 ICMS70 ICMS90 ICMSPart].freeze
      ICMS_FCP_ON_FCP_BASE = %w[ICMS10 ICMS20 ICMS51 ICMS70 ICMS90].freeze
      # Variants whose ST value is the ST tax less the operation's own ICMS, both in the group.
      ICMS_ST_LESS_OWN = %w[ICMS10 ICMS70 ICMSPart].freeze
      ST_MARGIN_MODE = "4"
      INTERSTATE = 2
      RATE_PLACES = 4

      module_function

      # Fills the derivable values of one resolved <det> hash, in dependency order.
      def call(item, context)
        imposto = item["imposto"] or return item

        ipi(imposto)
        icms(item, imposto, context)
        %w[PIS COFINS].each { |name| contribution(imposto, name) }
        destination_share(imposto, context)
        selective(imposto)
        ibs_cbs(item, imposto, context)
        item
      end

      # --- ICMS, IPI, PIS/COFINS ---

      def ipi(imposto)
        group = imposto.dig("IPI", "IPITrib") or return
        fill(group, "vIPI") { per_unit_or_percent(group, "vBC", "pIPI", "qUnid", "vUnid") }
      end

      def icms(item, imposto, context)
        name, group = (imposto["ICMS"] || {}).first
        return unless group

        if context.destination.to_i == INTERSTATE && group.key?("vBC") && group["pICMS"].nil? && (ICMS_RATED + ["ICMS51"]).include?(name)
          group["pICMS"] = Rates.interstate(context.origin_state, context.destination_state, group["orig"])
        end

        if name == "ICMS51"
          fill(group, "vICMSOp") { percent(group["vBC"], group["pICMS"]) if present?(group, "vBC", "pICMS") }
          fill(group, "vICMSDif") { percent(group["vICMSOp"], group["pDif"]) if present?(group, "vICMSOp", "pDif") }
          fill(group, "vICMS") { number(group["vICMSOp"]) - number(group["vICMSDif"]) if present?(group, "vICMSOp") }
        end
        fill(group, "vICMS") { expected_icms(name, group) }
        fill(group, "vFCP") { expected_fcp(name, group) }

        fill(group, "vBCST") { st_base(item, group) if ICMS_ST_LESS_OWN.include?(name) }
        fill(group, "vICMSST") { expected_icms_st(name, group) }
        fill(group, "vFCPST") { percent(group["vBCFCPST"], group["pFCPST"]) if present?(group, "vBCFCPST", "pFCPST") }
        fill(group, "vFCPSTRet") { percent(group["vBCFCPSTRet"], group["pFCPSTRet"]) if present?(group, "vBCFCPSTRet", "pFCPSTRet") }
      end

      # vBCST by margin (modBCST 4): the operation value with IPI, plus the MVA, less the
      # base reduction.
      def st_base(item, group)
        return unless group["modBCST"].to_s == ST_MARGIN_MODE && present?(group, "pMVAST")

        prod = item["prod"] || {}
        value = number(prod["vProd"]) - number(prod["vDesc"]) + number(prod["vFrete"]) + number(prod["vSeg"]) +
          number(prod["vOutro"]) + number(item.dig("imposto", "IPI", "IPITrib", "vIPI"))
        value * (1 + number(group["pMVAST"]) / HUNDRED) * (1 - number(group["pRedBCST"]) / HUNDRED)
      end

      def contribution(imposto, name)
        rate = "p#{name}"
        amount = "v#{name}"
        (imposto[name] || {}).each_value do |group|
          fill(group, amount) { per_unit_or_percent(group, "vBC", rate, "qBCProd", "vAliqProd") } if group.is_a?(Hash)
        end
        group = imposto["#{name}ST"] or return
        fill(group, amount) { per_unit_or_percent(group, "vBC", rate, "qBCProd", "vAliqProd") }
      end

      # ICMSUFDest (DIFAL, EC 87/2015).
      def destination_share(imposto, context)
        group = imposto["ICMSUFDest"] or return
        _, icms = (imposto["ICMS"] || {}).first
        group["pICMSInter"] ||= Rates.interstate(context.origin_state, context.destination_state, icms&.dig("orig"))
        group["pICMSInterPart"] ||= context.year && Rates.partition(context.year)

        fill(group, "vFCPUFDest") { expected_destination_fcp(group) }
        destination, origin = expected_destination_shares(group)
        fill(group, "vICMSUFDest") { destination }
        fill(group, "vICMSUFRemet") { origin && origin + destination - number(group["vICMSUFDest"]) }
      end

      def selective(imposto)
        group = imposto["IS"] or return
        fill(group, "vIS") { expected_selective(group) }
      end

      # --- IBS / CBS ---

      def ibs_cbs(item, imposto, context)
        ibscbs = imposto["IBSCBS"] or return
        klass = Tables.classification(ibscbs["cClassTrib"])
        ibscbs["CST"] ||= ibscbs["cClassTrib"].to_s[0, 3] if ibscbs["cClassTrib"]

        if ibscbs["gIBSCBS"].nil? && klass&.taxed? && !klass.monophase? && ibscbs["gIBSCBSMono"].nil?
          ibscbs["gIBSCBS"] = {}
        end
        group = ibscbs["gIBSCBS"] or return

        fill(group, "vBC") { ibs_cbs_base(item) }
        rates = context.year ? Rates.ibs_cbs(context.year) : {}
        spheres = [
          ["gIBSUF", "pIBSUF", "vIBSUF", rates[:uf], klass&.ibs_reduction],
          ["gIBSMun", "pIBSMun", "vIBSMun", rates[:municipal], klass&.ibs_reduction],
          ["gCBS", "pCBS", "vCBS", rates[:cbs], klass&.cbs_reduction]
        ]
        spheres.each do |tag, rate_tag, amount_tag, standard, reduction|
          sphere = (group[tag] ||= {})
          sphere[rate_tag] = standard if sphere[rate_tag].nil? && standard
          reduce(sphere, rate_tag, klass, reduction, context.purchase_reduction)
          fill(sphere["gDif"], "vDif") { expected_deferral(group, sphere, rate_tag) } if sphere["gDif"]
          fill(sphere, amount_tag) { expected_ibs_cbs(group, sphere, rate_tag) }
        end
        fill(group, "vIBS") do
          number(group.dig("gIBSUF", "vIBSUF")) + number(group.dig("gIBSMun", "vIBSMun")) if group["gIBSUF"] || group["gIBSMun"]
        end
      end

      # gRed when the classification reduces the rate, or on a government purchase (UB28-10);
      # then the effective rate.
      def reduce(sphere, rate_tag, klass, reduction, purchase)
        reduced = klass&.rate_reduction? && reduction&.positive?
        sphere["gRed"] ||= {"pRedAliq" => reduced ? reduction : BigDecimal(0)} if reduced || purchase
        red = sphere["gRed"] or return
        return if sphere[rate_tag].nil? || red["pRedAliq"].nil?

        red["pAliqEfet"] ||= effective_rate(sphere[rate_tag], red["pRedAliq"], purchase)
      end

      # pAliqEfet = rate x (1 - reduction) [x (1 - government purchase reducer)], 4 places.
      def effective_rate(rate, reduction, purchase = nil)
        value = number(rate) * (1 - number(reduction) / HUNDRED)
        value *= (1 - number(purchase) / HUNDRED) if purchase
        value.round(RATE_PLACES, half: :up)
      end

      # The rate a sphere is charged at: the effective one when reduced.
      def sphere_rate(sphere, rate_tag) = sphere.dig("gRed", "pAliqEfet") || sphere[rate_tag]

      # vDif = vBC x rate x pDif (UB23-10, UB42-10, UB61-10).
      def expected_deferral(group, sphere, rate_tag)
        rate = sphere_rate(sphere, rate_tag)
        deferral = sphere.dig("gDif", "pDif")
        return if group["vBC"].nil? || rate.nil? || deferral.nil?

        percent(percent(group["vBC"], rate), deferral)
      end

      # vIBSUF / vIBSMun / vCBS = vBC x rate - vDif - vDevTrib (UB35-10, UB54-10, UB67-10).
      def expected_ibs_cbs(group, sphere, rate_tag)
        rate = sphere_rate(sphere, rate_tag)
        return if group["vBC"].nil? || rate.nil?

        percent(group["vBC"], rate) - number(sphere.dig("gDif", "vDif")) - number(sphere.dig("gDevTrib", "vDevTrib"))
      end

      # gIBSCBS/vBC (UB16-10): the operation value without the taxes "por dentro".
      def ibs_cbs_base(item)
        prod = item["prod"] || {}
        imposto = item["imposto"] || {}
        _, icms = (imposto["ICMS"] || {}).first
        icms ||= {}
        base = number(prod["vProd"]) + number(prod["vFrete"]) + number(prod["vSeg"]) + number(prod["vOutro"]) +
          number(imposto.dig("II", "vII")) - number(prod["vDesc"])
        base -= %w[PIS COFINS].sum(BigDecimal(0)) { |name| contribution_amount(imposto, name) }
        base -= number(icms["vICMS"]) + number(icms["vFCP"]) + number(icms["vICMSMono"])
        base -= number(imposto.dig("ICMSUFDest", "vICMSUFDest")) + number(imposto.dig("ICMSUFDest", "vFCPUFDest"))
        base -= number(imposto.dig("ISSQN", "vISSQN"))
        base + number(imposto.dig("IS", "vIS"))
      end

      # PIS (or COFINS) taken out of the IBS/CBS base: the normal group, and the ST one unless it
      # is added to the invoice total (indSomaPISST / indSomaCOFINSST).
      def contribution_amount(imposto, name)
        _, group = (imposto[name] || {}).first
        amount = number(group.is_a?(Hash) ? group["v#{name}"] : nil)
        st = imposto["#{name}ST"]
        amount += number(st["v#{name}"]) if st && st["indSoma#{name}ST"].to_s != "1"
        amount
      end

      # --- Expected values (shared with the Validator) ---

      def expected_icms(name, group)
        percent(group["vBC"], group["pICMS"]) if ICMS_RATED.include?(name) && present?(group, "vBC", "pICMS")
      end

      # RV N17c-10.
      def expected_fcp(name, group)
        base = (name == "ICMS00") ? "vBC" : ("vBCFCP" if ICMS_FCP_ON_FCP_BASE.include?(name))
        percent(group[base], group["pFCP"]) if base && present?(group, base, "pFCP")
      end

      def expected_icms_st(name, group)
        return unless ICMS_ST_LESS_OWN.include?(name) && present?(group, "vBCST", "pICMSST")

        percent(group["vBCST"], group["pICMSST"]) - number(group["vICMS"])
      end

      # RV NA13-10.
      def expected_destination_fcp(group)
        percent(group["vBCFCPUFDest"], group["pFCPUFDest"]) if present?(group, "vBCFCPUFDest", "pFCPUFDest")
      end

      # [vICMSUFDest, vICMSUFRemet] (RV NA15-10, NA17-10), or nil.
      def expected_destination_shares(group)
        return unless present?(group, "vBCUFDest", "pICMSUFDest", "pICMSInter", "pICMSInterPart")

        difference = percent(group["vBCUFDest"], number(group["pICMSUFDest"]) - number(group["pICMSInter"]))
        destination = percent(difference, group["pICMSInterPart"])
        [destination, difference - destination]
      end

      # RV UB11-10, ad valorem only.
      def expected_selective(group)
        percent(group["vBCIS"], group["pIS"]) if group["adRemIS"].nil? && present?(group, "vBCIS", "pIS")
      end

      # --- helpers ---

      def per_unit_or_percent(group, base, rate, quantity, unit)
        if present?(group, base, rate)
          percent(group[base], group[rate])
        elsif present?(group, quantity, unit)
          number(group[quantity]) * number(group[unit])
        end
      end

      def percent(base, rate) = number(base) * number(rate) / HUNDRED

      def number(value) = Totals.number(value)

      def present?(group, *tags) = tags.all? { |tag| !group[tag].nil? && group[tag] != "" }

      # Sets group[tag] to the block's value rounded as the XML shows it, unless it is given.
      def fill(group, tag)
        return unless group.is_a?(Hash) && group[tag].nil?

        value = yield
        group[tag] = Totals.money(value) unless value.nil?
      end
    end
  end
end
