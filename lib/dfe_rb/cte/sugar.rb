module DfeRb
  module Cte
    module Sugar
      HANDLERS = {}
      EXTERIOR = %w[9999999 EXTERIOR].freeze
      TAKER_ROLES = {sender: 0, dispatcher: 1, receiver: 2, recipient: 3}.freeze
      ICMS_BY_CST = {
        "00" => "ICMS00", "20" => "ICMS20", "40" => "ICMS45", "41" => "ICMS45",
        "51" => "ICMS45", "60" => "ICMS60", "90" => "ICMS90"
      }.freeze

      class << self
        def handler(tag, key)
          HANDLERS[[tag, key]]
        end

        def register(tag, key, &block)
          HANDLERS[[tag, key]] = block
        end

        def city(args, kwargs)
          first, second = args
          options = (first.is_a?(Hash) ? first.merge(kwargs) : kwargs).transform_keys(&:to_sym)
          first = nil if first.is_a?(Hash)
          code = options[:city_code] || (first if first.to_s.match?(/\A\d{7}\z/))
          name = options[:city] || (first unless code && first.to_s == code.to_s)
          state = options[:state] || second
          raise ArgumentError, "give the city's IBGE code, or its name and state" if code.nil? && (name.nil? || state.nil?)

          code ||= Cities.code(name, state) or raise ArgumentError, "no city called #{name.inspect} in #{state} (give its IBGE code)"
          resolved_state = state ? state.to_s.upcase : state_from_code(code.to_s)
          resolved_name = Cities.name(code) || name || (EXTERIOR.last if code.to_s == EXTERIOR.first)
          [code.to_s, resolved_name, resolved_state]
        end

        def state_from_code(code)
          return "EX" if code == EXTERIOR.first

          DfeRb::States::CODES.key(code[0, 2].to_i)
        end

        def tax_id(data, value, cnpj: "CNPJ", cpf: "CPF")
          id = TaxId.normalize(value)
          data.delete(cnpj)
          data.delete(cpf)
          data[(id.length == 11) ? cpf : cnpj] = id
          nil
        end

        def attributes(args, kwargs)
          first = args.first
          first.is_a?(Hash) ? first.merge(kwargs) : kwargs
        end
      end

      register("infCte", "origin") do |_scope, data, args, kwargs, _block|
        code, name, state = city(args, kwargs)
        ide = (data["ide"] ||= {})
        ide["cMunIni"] = code
        ide["xMunIni"] = name
        ide["UFIni"] = state if state
        nil
      end

      register("infCte", "destination") do |_scope, data, args, kwargs, _block|
        code, name, state = city(args, kwargs)
        ide = (data["ide"] ||= {})
        ide["cMunFim"] = code
        ide["xMunFim"] = name
        ide["UFFim"] = state if state
        nil
      end

      register("infCte", "sent_from") do |_scope, data, args, kwargs, _block|
        code, name, state = city(args, kwargs)
        ide = (data["ide"] ||= {})
        ide["cMunEnv"] = code
        ide["xMunEnv"] = name
        ide["UFEnv"] = state if state
        nil
      end

      register("infCte", "taker") do |scope, data, args, kwargs, block|
        ide = (data["ide"] ||= {})
        first = args.first
        if (first.is_a?(Symbol) || first.is_a?(Integer) || first.is_a?(String)) && kwargs.empty? && block.nil?
          code = first.is_a?(Symbol) ? TAKER_ROLES.fetch(first) { Names.enum_value("toma", first) } : first.to_i
          raise ArgumentError, "for taker :other (4), pass the taker's details (tax_id:, name:, address:)" if code == 4

          ide.delete("toma4")
          ide["toma3"] = {"toma" => code}
          nil
        else
          ide.delete("toma3")
          toma4 = (ide["toma4"] ||= {"toma" => 4})
          toma4["toma"] = 4
          inner = scope.__child(scope.__element.find("ide").find("toma4"), toma4)
          attrs = attributes(args, kwargs)
          inner.__assign(attrs) unless attrs.empty?
          block&.call(inner)
          toma4
        end
      end

      register("infCte", "freight") do |scope, data, args, kwargs, block|
        vprest = (data["vPrest"] ||= {})
        inner = scope.__child(scope.__element.find("vPrest"), vprest)
        attrs = attributes(args, kwargs)
        inner.__assign(attrs) unless attrs.empty?
        block&.call(inner)
        vprest
      end

      register("infCte", "icms") do |scope, data, args, kwargs, block|
        options = attributes(args, kwargs).transform_keys(&:to_sym)
        icms_data = ((data["imp"] ||= {})["ICMS"] = {})
        icms_el = scope.__element.find("imp").find("ICMS")
        group_tag = if options.delete(:simples) || options[:indSN]
          options[:cst] ||= "90"
          options[:simples] = 1
          "ICMSSN"
        elsif options.delete(:other_state)
          options[:cst] ||= "90"
          "ICMSOutraUF"
        elsif options.key?(:forecast_amount) || options.key?(:vICMSPrevisto)
          "gICMSPrevistoPagtoAntecip"
        else
          cst = (options[:cst] || options[:CST]).to_s.rjust(2, "0")
          ICMS_BY_CST.fetch(cst) do
            raise ArgumentError, "unknown ICMS CST #{options[:cst].inspect} (use #{ICMS_BY_CST.keys.join(", ")}, simples: true, or other_state: true)"
          end
        end
        group = (icms_data[group_tag] = {})
        inner = scope.__child(icms_el.find(group_tag), group)
        inner.__assign(options) unless options.empty?
        block&.call(inner)
        group
      end

      register("infCte", "contingency") do |_scope, data, args, kwargs, _block|
        mode = args.first
        ide = (data["ide"] ||= {})
        case mode
        when false, :normal
          ide["tpEmis"] = 1
          ide.delete("dhCont")
          ide.delete("xJust")
        when :svc, true, nil
          ide["tpEmis"] = :svc
          ide.delete("dhCont")
          ide.delete("xJust")
        when :svc_rs
          ide["tpEmis"] = 7
          ide.delete("dhCont")
          ide.delete("xJust")
        when :svc_sp
          ide["tpEmis"] = 8
          ide.delete("dhCont")
          ide.delete("xJust")
        when :offline
          ide["tpEmis"] = 2
          ide["dhCont"] = kwargs[:since] if kwargs.key?(:since)
          ide["xJust"] = kwargs[:reason] if kwargs.key?(:reason)
        when :epec
          ide["tpEmis"] = 4
        else
          raise ArgumentError, "unknown contingency mode #{mode.inspect} (use :svc, :svc_rs, :svc_sp, :offline, :epec, or false)"
        end
        nil
      end

      register("infCte", "complement") do |_scope, data, args, _kwargs, _block|
        (data["ide"] ||= {})["tpCTe"] = 1
        list = (data["infCteComp"] ||= [])
        args.flatten.each { |key| list << {"chCTe" => key.to_s} }
        nil
      end

      register("infCte", "substitute") do |_scope, data, args, kwargs, _block|
        (data["ide"] ||= {})["tpCTe"] = 3
        sub = ((data["infCTeNorm"] ||= {})["infCteSub"] ||= {})
        sub["chCte"] = (args.first || kwargs[:key]).to_s
        sub["indAlteraToma"] = 1 if kwargs[:change_taker]
        nil
      end

      register("infCte", "previous_cte") do |scope, data, args, kwargs, _block|
        keys = Array(args.first || kwargs[:key] || kwargs[:keys]).map(&:to_s)
        issuer = (kwargs[:issuer] || {}).transform_keys(&:to_sym)
        emi = {}
        emi_el = scope.__element.find("infCTeNorm").find("docAnt").find("emiDocAnt")
        scope.__child(emi_el, emi).__assign(issuer) unless issuer.empty?
        emi["idDocAnt"] = [{"idDocAntEle" => keys.map { |k| {"chCTe" => k} }}]
        (((data["infCTeNorm"] ||= {})["docAnt"] ||= {})["emiDocAnt"] ||= []) << emi
        nil
      end

      register("infCte", "payment_link") do |scope, data, args, kwargs, block|
        options = attributes(args.drop(1), kwargs)
        options = {method: args.first}.merge(options) if args.first && !args.first.is_a?(Hash)
        options = attributes(args, kwargs) if args.first.is_a?(Hash)
        pgto = {}
        ((data["pgtoVinc"] ||= {})["pgto"] ||= []) << pgto
        inner = scope.__child(scope.__element.find("pgtoVinc").find("pgto"), pgto)
        inner.__assign(options) unless options.empty?
        block&.call(inner)
        pgto
      end

      register("infCte", "authorized_downloader") do |_scope, data, args, _kwargs, _block|
        args.flatten.each { |value| tax_id((data["autXML"] ||= []).push({}).last, value) }
        nil
      end

      %w[emit rem exped receb dest toma4 emiDocAnt].each do |tag|
        register(tag, "tax_id") { |_scope, data, args, _kwargs, _block| tax_id(data, args.first) }
      end
    end
  end
end
