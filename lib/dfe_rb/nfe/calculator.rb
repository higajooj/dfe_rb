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
      # the issue year, the government purchase reducer (ide/gCompraGov/pRedutor), finNFe and
      # the item's CFOP (set by `call`). Rates fixed by law are filled in only for a normal
      # operation (finNFe 1): a return, adjustment or complement carries the rates of the
      # operation it refers to, which only the issuer knows.
      Context = Struct.new(:origin_state, :destination_state, :destination, :year, :purchase_reduction, :purpose, :cfop) do
        def law_rates? = purpose.to_s == NORMAL

        # The interstate ICMS rates (RV N16-04, N16-20, NA09-30, NA11-10) don't bind a
        # retorno or an anulação CFOP either: it carries the rates of the operation it refers to.
        def interstate_rates? = law_rates? && !Tables.cfop(cfop)&.then { |row| row.goods_return? || row.annulment? }
      end

      NORMAL = "1"
      HUNDRED = BigDecimal(100)
      ICMS_RATED = %w[ICMS00 ICMS10 ICMS20 ICMS70 ICMS90 ICMSPart].freeze
      ICMS_FCP_ON_FCP_BASE = %w[ICMS10 ICMS20 ICMS51 ICMS70 ICMS90].freeze
      # Variants whose ST value is the ST tax less the operation's own ICMS, both in the group.
      ICMS_ST_LESS_OWN = %w[ICMS10 ICMS70 ICMSPart].freeze
      INTERSTATE = 2
      RATE_PLACES = 4

      module_function

      # Fills the derivable values of one resolved <det> hash, in dependency order.
      def call(item, context)
        imposto = item["imposto"] or return item
        context = context.dup.tap { |copy| copy.cfop = item.dig("prod", "CFOP") }

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

        if context.interstate_rates? && context.destination.to_i == INTERSTATE && group.key?("vBC") && group["pICMS"].nil? && (ICMS_RATED + ["ICMS51"]).include?(name)
          group["pICMS"] = Rates.interstate(context.origin_state, context.destination_state, group["orig"])
        end

        if name == "ICMS51"
          fill(group, "vICMSOp") { percent(group["vBC"], group["pICMS"]) if present?(group, "vBC", "pICMS") }
          fill(group, "vICMSDif") { percent(group["vICMSOp"], group["pDif"]) if present?(group, "vICMSOp", "pDif") }
          fill(group, "vICMS") { money(group["vICMSOp"]) - money(group["vICMSDif"]) if present?(group, "vICMSOp") }
        end
        fill(group, "vICMS") { expected_icms(name, group) }
        fill(group, "vFCP") { expected_fcp(name, group) }

        fill(group, "vICMSST") { expected_icms_st(name, group) }
        fill(group, "vFCPST") { percent(group["vBCFCPST"], group["pFCPST"]) if present?(group, "vBCFCPST", "pFCPST") }
        fill(group, "vFCPSTRet") { percent(group["vBCFCPSTRet"], group["pFCPSTRet"]) if present?(group, "vBCFCPSTRet", "pFCPSTRet") }
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
        if context.interstate_rates?
          # An enumeration in the schema ("4.00", "7.00", "12.00"): written with its two places.
          group["pICMSInter"] ||= Rates.interstate(context.origin_state, context.destination_state, icms&.dig("orig"))&.then { |rate| format("%.2f", rate) }
          group["pICMSInterPart"] ||= context.year && Rates.partition(context.year)
        end

        fill(group, "vFCPUFDest") { expected_destination_fcp(group) }
        destination, origin = expected_destination_shares(group)
        fill(group, "vICMSUFDest") { destination }
        fill(group, "vICMSUFRemet") { origin && origin + destination - money(group["vICMSUFDest"]) }
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
        rates = (context.law_rates? && context.year) ? Rates.ibs_cbs(context.year) : {}
        # A classification under the regular taxation group is charged nothing in the main
        # one (UB18-10, UB37-10, UB56-10, exception 1).
        rates = rates.transform_values { |rate| rate && BigDecimal(0) } if klass&.regular_taxation?
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
          # A CST that requires deferral (ind_gDif) has no amount until the deferral is given.
          next if klass&.deferral? && sphere["gDif"].nil?

          fill(sphere, amount_tag) { expected_ibs_cbs(group, sphere, rate_tag) }
        end
        fill(group, "vIBS") do
          amounts = [group.dig("gIBSUF", "vIBSUF"), group.dig("gIBSMun", "vIBSMun")]
          amounts.sum(BigDecimal(0)) { |amount| money(amount) } if amounts.none?(&:nil?)
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
        value = percentage(rate) * (1 - percentage(reduction) / HUNDRED)
        value *= (1 - percentage(purchase) / HUNDRED) if purchase
        value.round(RATE_PLACES, half: :up)
      end

      # The rate a sphere is charged at: the effective one when reduced.
      def sphere_rate(sphere, rate_tag) = sphere.dig("gRed", "pAliqEfet") || sphere[rate_tag]

      # vDif = vBC x rate x pDif (UB23-10, UB42-10, UB61-10).
      def expected_deferral(group, sphere, rate_tag)
        rate = sphere_rate(sphere, rate_tag)
        deferral = sphere.dig("gDif", "pDif")
        return if group["vBC"].nil? || rate.nil? || deferral.nil?

        share(percent(group["vBC"], rate), deferral)
      end

      # vIBSUF / vIBSMun / vCBS = vBC x rate - vDif - vDevTrib (UB35-10, UB54-10, UB67-10).
      def expected_ibs_cbs(group, sphere, rate_tag)
        rate = sphere_rate(sphere, rate_tag)
        return if group["vBC"].nil? || rate.nil?

        percent(group["vBC"], rate) - money(sphere.dig("gDif", "vDif")) - money(sphere.dig("gDevTrib", "vDevTrib"))
      end

      # gIBSCBS/vBC (UB16-10): the operation value without the taxes "por dentro".
      def ibs_cbs_base(item)
        prod = item["prod"] || {}
        imposto = item["imposto"] || {}
        _, icms = (imposto["ICMS"] || {}).first
        icms ||= {}
        base = money(prod["vProd"]) + money(prod["vFrete"]) + money(prod["vSeg"]) + money(prod["vOutro"]) +
          money(imposto.dig("II", "vII")) - money(prod["vDesc"])
        base -= %w[PIS COFINS].sum(BigDecimal(0)) { |name| contribution_amount(imposto, name) }
        base -= money(icms["vICMS"]) + money(icms["vFCP"]) + money(icms["vICMSMono"])
        base -= money(imposto.dig("ICMSUFDest", "vICMSUFDest")) + money(imposto.dig("ICMSUFDest", "vFCPUFDest"))
        base -= money(imposto.dig("ISSQN", "vISSQN"))
        base + money(imposto.dig("IS", "vIS"))
      end

      # PIS (or COFINS) taken out of the IBS/CBS base: the normal group, and the ST one unless it
      # is added to the invoice total (indSomaPISST / indSomaCOFINSST).
      def contribution_amount(imposto, name)
        _, group = (imposto[name] || {}).first
        amount = money(group.is_a?(Hash) ? group["v#{name}"] : nil)
        st = imposto["#{name}ST"]
        amount += money(st["v#{name}"]) if st && st["indSoma#{name}ST"].to_s != "1"
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

        percent(group["vBCST"], group["pICMSST"]) - money(group["vICMS"])
      end

      # RV NA13-10.
      def expected_destination_fcp(group)
        percent(group["vBCFCPUFDest"], group["pFCPUFDest"]) if present?(group, "vBCFCPUFDest", "pFCPUFDest")
      end

      # [vICMSUFDest, vICMSUFRemet] (RV NA15-10, NA17-10), or nil.
      def expected_destination_shares(group)
        return unless present?(group, "vBCUFDest", "pICMSUFDest", "pICMSInter", "pICMSInterPart")

        difference = percent(group["vBCUFDest"], percentage(group["pICMSUFDest"]) - percentage(group["pICMSInter"]))
        destination = share(difference, group["pICMSInterPart"])
        [destination, difference - destination]
      end

      # RV UB11-10, ad valorem only.
      def expected_selective(group)
        percent(group["vBCIS"], group["pIS"]) if group["adRemIS"].nil? && present?(group, "vBCIS", "pIS")
      end

      # --- helpers ---
      #
      # Operands are taken as the XML writes them (amounts with 2 places; rates, quantities and
      # unit values with 4), so a result always agrees with the values printed next to it.

      def per_unit_or_percent(group, base, rate, quantity, unit)
        if present?(group, base, rate)
          percent(group[base], group[rate])
        elsif present?(group, quantity, unit)
          percentage(group[quantity]) * percentage(group[unit])
        end
      end

      # An amount times a rate in percent.
      def percent(base, rate) = share(money(base), rate)

      # A value already computed (not printed) times a rate in percent.
      def share(value, rate) = number(value) * percentage(rate) / HUNDRED

      def percentage(value) = number(value).round(RATE_PLACES, half: :up)

      def money(value) = Totals.money(value)

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
