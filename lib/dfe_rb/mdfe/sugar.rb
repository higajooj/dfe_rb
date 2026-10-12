module DfeRb
  module Mdfe
    # Builder conveniences that don't map 1:1 to a schema child: the cities a manifest loads
    # and unloads at (given by IBGE code or by name and state), the states it crosses, the
    # cargo totals and `tax_id`, which picks CNPJ or CPF.
    module Sugar
      HANDLERS = {}
      EXTERIOR = %w[9999999 EXTERIOR].freeze

      class << self
        # The handler for `key` used on the element `tag`, or nil.
        def handler(tag, key)
          HANDLERS[[tag, key]]
        end

        def register(tag, key, &block)
          HANDLERS[[tag, key]] = block
        end

        # [IBGE code, name] of a city given as a code ("3550308"), as a name and a state
        # ("Sao Paulo", "SP") or with city_code:/city:/state:. The name written is the IBGE
        # table's. A name the table lacks raises, so a typo shows where it was made.
        def city(args, kwargs)
          first, second = args
          options = (first.is_a?(Hash) ? first.merge(kwargs) : kwargs).transform_keys(&:to_sym)
          first = nil if first.is_a?(Hash)
          code = options[:city_code] || (first if first.to_s.match?(/\A\d{7}\z/))
          name = options[:city] || (first unless code && first.to_s == code.to_s)
          state = options[:state] || second
          raise ArgumentError, "give the city's IBGE code, or its name and state" if code.nil? && (name.nil? || state.nil?)

          code ||= Cities.code(name, state) or raise ArgumentError, "no city called #{name.inspect} in #{state} (give its IBGE code)"
          [code.to_s, Cities.name(code) || name || (EXTERIOR.last if code.to_s == EXTERIOR.first)]
        end

        def tax_id(data, value, cnpj: "CNPJ", cpf: "CPF")
          id = TaxId.normalize(value)
          data.delete(cnpj)
          data.delete(cpf)
          data[(id.length == 11) ? cpf : cnpj] = id
          nil
        end
      end

      # `load_at "Sao Paulo", "SP"` or `load_at "3550308"` appends <infMunCarrega>.
      register("infMDFe", "load_at") do |_scope, data, args, kwargs, _block|
        code, name = city(args, kwargs)
        ((data["ide"] ||= {})["infMunCarrega"] ||= []) << {"cMunCarrega" => code, "xMunCarrega" => name}
        nil
      end

      # `unload_at "Rio de Janeiro", "RJ" do |u| u.nfe "3526..." end` (or `nfe: [...]`,
      # `cte: [...]`, `mdfe: [...]`) is one <infMunDescarga> with its documents. Naming a
      # city again adds to its documents, since a city may appear only once (F13).
      register("infMDFe", "unload_at") do |scope, data, args, kwargs, block|
        documents = kwargs.slice(:nfe, :cte, :mdfe)
        code, name = city(args, kwargs.except(:nfe, :cte, :mdfe))
        cities = ((data["infDoc"] ||= {})["infMunDescarga"] ||= [])
        entry = cities.find { |known| known["cMunDescarga"] == code }
        cities << (entry = {"cMunDescarga" => code, "xMunDescarga" => name}) unless entry

        inner = scope.__child(scope.__element.find("infDoc").find("infMunDescarga"), entry)
        documents.each { |kind, keys| Array(keys).each { |key| inner.__apply(kind.to_s, [key], {}, nil) } }
        block&.call(inner)
        entry
      end

      # `route "MG", "GO"`: the states crossed between the first and the last, in order.
      register("infMDFe", "route") do |_scope, data, args, _kwargs, _block|
        list = ((data["ide"] ||= {})["infPercurso"] ||= [])
        args.flatten.each { |state| list << {"UFPer" => state.to_s.upcase} }
        nil
      end

      # `cargo value: "15000.00", weight: "1200.5"` (weight in kg unless `unit: :ton`).
      register("infMDFe", "cargo") do |_scope, data, args, kwargs, _block|
        options = Sugar.attributes(args, kwargs).transform_keys(&:to_sym)
        unknown = options.keys - %i[value weight unit]
        raise ArgumentError, "cargo takes value:, weight: and unit: (got #{unknown.map(&:inspect).join(", ")})" unless unknown.empty?

        tot = (data["tot"] ||= {})
        tot["vCarga"] = options[:value] if options.key?(:value)
        tot["qCarga"] = options[:weight] if options.key?(:weight)
        unit = options[:unit]
        tot["cUnid"] = unit.is_a?(Symbol) ? Names.enum_value("cUnid", unit) : unit if unit
        nil
      end

      # `contingency` makes the manifest one issued off-line (tpEmis 2), to print and carry
      # now and transmit within 168 hours (MOC 11).
      register("infMDFe", "contingency") do |_scope, data, args, _kwargs, _block|
        (data["ide"] ||= {})["tpEmis"] = (args.first == false) ? 1 : 2
        nil
      end

      # `authorized_downloader "12345678000195"` appends <autXML>.
      register("infMDFe", "authorized_downloader") do |_scope, data, args, _kwargs, _block|
        args.flatten.each { |value| tax_id((data["autXML"] ||= []).push({}).last, value) }
        nil
      end

      # A CNPJ or CPF, told apart by length: `issuer tax_id: "..."`.
      %w[emit prop infCIOT infContratante infPag infResp].each do |tag|
        register(tag, "tax_id") { |_scope, data, args, _kwargs, _block| tax_id(data, args.first) }
      end
      register("seg", "tax_id") { |_scope, data, args, _kwargs, _block| tax_id(data["infResp"] ||= {}, args.first) }

      # Who paid the toll voucher: `toll_voucher supplier: "...", payer: "...", amount: "50.00"`.
      register("disp", "payer") { |_scope, data, args, _kwargs, _block| tax_id(data, args.first, cnpj: "CNPJPg", cpf: "CPFPg") }

      def self.attributes(args, kwargs)
        first = args.first
        first.is_a?(Hash) ? first.merge(kwargs) : kwargs
      end
    end
  end
end
