module DfeRb
  module Nfe
    # Builder conveniences that don't map 1:1 to a schema child: the tax helpers pick the right
    # XML group from the CST/CSOSN (`icms cst: "00"` becomes <ICMS00>), and `tax_id` picks
    # CNPJ or CPF. Everything else about these groups stays reachable by name.
    module Sugar
      ICMS_BY_CST = {
        "00" => "ICMS00", "02" => "ICMS02", "10" => "ICMS10", "15" => "ICMS15", "20" => "ICMS20", "30" => "ICMS30",
        "40" => "ICMS40", "41" => "ICMS40", "50" => "ICMS40", "51" => "ICMS51", "53" => "ICMS53", "60" => "ICMS60",
        "61" => "ICMS61", "70" => "ICMS70", "90" => "ICMS90"
      }.freeze

      ICMS_BY_CSOSN = {
        "101" => "ICMSSN101", "102" => "ICMSSN102", "103" => "ICMSSN102", "201" => "ICMSSN201", "202" => "ICMSSN202",
        "203" => "ICMSSN202", "300" => "ICMSSN102", "400" => "ICMSSN102", "500" => "ICMSSN500", "900" => "ICMSSN900"
      }.freeze

      IPI_TAXED_CST = %w[00 49 50 99].freeze
      IPI_LEVEL_TAGS = %w[CNPJProd cSelo qSelo cEnq].freeze

      HANDLERS = {}

      class << self
        # The handler for `key` used on the element `tag`, or nil.
        def handler(tag, key)
          HANDLERS[[tag, key]]
        end

        def register(tag, key, &block)
          HANDLERS[[tag, key]] = block
        end

        # Keyword and hash arguments as one Hash.
        def attributes(args, kwargs)
          first = args.first
          first.is_a?(Hash) ? first.merge(kwargs) : kwargs
        end

        # The schema tag `key` stands for in a group: English name (via `table`), the tag
        # itself, or its snake_case form.
        def tag_for(key, table, known_tags)
          return table[key] if key.is_a?(Symbol) && table.key?(key)

          text = key.to_s
          return table[text.to_sym] if table.key?(text.to_sym)
          return text if known_tags.include?(text)

          known_tags.find { |tag| Names.snake(tag) == text }
        end

        def code_from(attributes, table, known)
          key = attributes.keys.find { |k| %w[CST CSOSN].include?(tag_for(k, table, known)) }
          [key, attributes[key]&.to_s]
        end

        def icms_variant(code, tags)
          if code.length == 3 || ICMS_BY_CSOSN.key?(code) && !ICMS_BY_CST.key?(code)
            ICMS_BY_CSOSN[code] or raise ArgumentError, "unknown CSOSN #{code.inspect} (use #{ICMS_BY_CSOSN.keys.join(", ")})"
          elsif (tags & %w[pBCOp UFST]).any?
            "ICMSPart"
          elsif (tags & %w[vBCSTDest vICMSSTDest]).any?
            "ICMSST"
          else
            ICMS_BY_CST[code] or raise ArgumentError, "unknown ICMS CST #{code.inspect} (use #{ICMS_BY_CST.keys.join(", ")})"
          end
        end

        def contribution_suffix(code)
          case code
          when "01", "02" then "Aliq"
          when "03" then "Qtde"
          when "04", "05", "06", "07", "08", "09" then "NT"
          else "Outr"
          end
        end

        # Builds <ICMS><ICMSxx> under det/imposto from the flat attributes.
        def icms(scope, data, args, kwargs, block)
          attributes = attributes(args, kwargs)
          icms = scope.__element.find("imposto").find("ICMS")
          known = icms.each_element.flat_map { |variant| variant.each_element.map(&:tag) }.uniq
          table = Names::ICMS
          tags = attributes.keys.filter_map { |key| tag_for(key, table, known) }
          key, code = code_from(attributes, table, known)
          raise ArgumentError, "icms needs cst: (or csosn:)" unless code

          code = code.rjust(2, "0")
          variant = icms_variant(code, tags)
          code_tag = variant.start_with?("ICMSSN") ? "CSOSN" : "CST"
          fields = attributes.reject { |k, _| k == key }.merge(code_tag => code)

          target = ((data["imposto"] ||= {})["ICMS"] ||= {})
          target.clear
          child = target[variant] = {}
          inner = Scope.new(icms.find(variant), child)
          inner.__assign(fields)
          block&.call(inner)
          nil
        end

        # PIS / COFINS: Aliq, Qtde, NT or Outr according to the CST.
        def contribution(name, scope, data, args, kwargs, block)
          attributes = attributes(args, kwargs)
          group = scope.__element.find("imposto").find(name)
          table = Names.table_for("#{name}Aliq")
          known = group.each_element.flat_map { |variant| variant.each_element.map(&:tag) }.uniq
          key, code = code_from(attributes, table, known)
          raise ArgumentError, "#{name.downcase} needs cst:" unless code

          code = code.rjust(2, "0")
          variant = "#{name}#{contribution_suffix(code)}"
          fields = attributes.reject { |k, _| k == key }.merge("CST" => code)

          child = ((data["imposto"] ||= {})[name] = {variant => {}})[variant]
          inner = Scope.new(group.find(variant), child)
          inner.__assign(fields)
          block&.call(inner)
          nil
        end

        # IPI: framework code and stamp go on <IPI>, the rest in IPITrib (CST 00/49/50/99) or IPINT.
        def ipi(scope, data, args, kwargs, block)
          attributes = attributes(args, kwargs)
          ipi = scope.__element.find("imposto").find("IPI")
          known = ipi.each_element.flat_map { |variant| variant.each_element.map(&:tag) }.uniq + IPI_LEVEL_TAGS
          table = Names::IPI
          key, code = code_from(attributes, table, known)
          raise ArgumentError, "ipi needs cst:" unless code

          code = code.rjust(2, "0")
          variant = IPI_TAXED_CST.include?(code) ? "IPITrib" : "IPINT"
          level = {"cEnq" => "999"}
          fields = {"CST" => code}
          attributes.each do |name, value|
            next if name == key

            tag = tag_for(name, table, known)
            (IPI_LEVEL_TAGS.include?(tag) ? level : fields)[tag || name.to_s] = value
          end

          target = ((data["imposto"] ||= {})["IPI"] = {})
          Scope.new(ipi, target).__assign(level)
          child = target[variant] = {}
          inner = Scope.new(ipi.find(variant), child)
          inner.__assign(fields)
          block&.call(inner)
          nil
        end

        # IBS/CBS: `base`, `ibs_uf`, `ibs_municipal`, `ibs` and `cbs` describe the usual
        # normal-tax case; anything else is given by official name (g_ibs_cbs: {...}).
        def ibs_cbs(scope, data, args, kwargs, block)
          attributes = attributes(args, kwargs).transform_keys(&:to_sym)
          group = {}
          group["vBC"] = attributes.delete(:base) if attributes.key?(:base)
          if (uf = attributes.delete(:ibs_uf))
            group["gIBSUF"] = ibs_part(uf, "pIBSUF", "vIBSUF")
          end
          if (municipal = attributes.delete(:ibs_municipal))
            group["gIBSMun"] = ibs_part(municipal, "pIBSMun", "vIBSMun")
          end
          group["vIBS"] = attributes.delete(:ibs) if attributes.key?(:ibs)
          if (cbs = attributes.delete(:cbs))
            group["gCBS"] = ibs_part(cbs, "pCBS", "vCBS")
          end
          attributes[:g_ibscbs] = (attributes[:g_ibscbs] || {}).merge(group) unless group.empty?

          target = ((data["imposto"] ||= {})["IBSCBS"] = {})
          inner = Scope.new(scope.__element.find("imposto").find("IBSCBS"), target)
          inner.__assign(attributes)
          block&.call(inner)
          nil
        end

        def ibs_part(values, rate_tag, amount_tag)
          values = values.transform_keys(&:to_sym)
          part = {}
          part[rate_tag] = values.delete(:rate) if values.key?(:rate)
          if (deferral = values.delete(:deferral))
            part["gDif"] = {"pDif" => deferral[:rate], "vDif" => deferral[:amount]}.compact
          end
          if values.key?(:devolution)
            part["gDevTrib"] = {"vDevTrib" => values.delete(:devolution)}
          end
          if (reduction = values.delete(:reduction))
            part["gRed"] = {"pRedAliq" => reduction[:rate], "pAliqEfet" => reduction[:effective_rate]}.compact
          end
          part[amount_tag] = values.delete(:amount) if values.key?(:amount)
          part.merge(values.transform_keys(&:to_s))
        end
      end

      register("det", "icms") { |scope, data, args, kwargs, block| icms(scope, data, args, kwargs, block) }
      register("det", "pis") { |scope, data, args, kwargs, block| contribution("PIS", scope, data, args, kwargs, block) }
      register("det", "cofins") { |scope, data, args, kwargs, block| contribution("COFINS", scope, data, args, kwargs, block) }
      register("det", "ipi") { |scope, data, args, kwargs, block| ipi(scope, data, args, kwargs, block) }
      register("det", "ibs_cbs") { |scope, data, args, kwargs, block| ibs_cbs(scope, data, args, kwargs, block) }

      # A CNPJ or CPF, told apart by length: `issuer tax_id: "..."`.
      %w[emit dest transporta].each do |tag|
        register(tag, "tax_id") do |_scope, data, args, _kwargs, _block|
          id = TaxId.normalize(args.first)
          data.delete("CNPJ")
          data.delete("CPF")
          data[(id.length == 11) ? "CPF" : "CNPJ"] = id
          nil
        end
      end

      # `authorized_downloader "12345678000195"` appends <autXML>.
      register("infNFe", "authorized_downloader") do |_scope, data, args, _kwargs, _block|
        Array(args.first).each do |value|
          id = TaxId.normalize(value)
          (data["autXML"] ||= []) << {((id.length == 11) ? "CPF" : "CNPJ") => id}
        end
        nil
      end
    end
  end
end
