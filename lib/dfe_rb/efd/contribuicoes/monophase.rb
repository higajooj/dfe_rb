module DfeRb
  module Efd
    module Contribuicoes
      # Goods whose PIS and COFINS the manufacturer or importer pays for the whole
      # chain (incidência monofásica): who resells them sells at a zero rate, with CST
      # 04, and books the revenue in M410/M810 by the nature of table 4.3.10 (001 fuels,
      # 002 medicines and perfumery, 003 vehicles, machines and parts), takes no credit
      # on buying them. Cold drinks a retailer resells are at a zero rate too (art. 28 of
      # Lei 13.097/2015), CST 06, nature 918 of table 4.3.13.
      #
      # The NCMs by group, as table 4.3.10 (version of 2026) lists them. Auto parts are
      # only chapter 87's (87.06 to 87.08): Anexos I and II of Lei 10.485/2002 also list
      # pipes, valves, wires and switches that a building supplies store sells for other
      # uses, which a check by NCM alone can't tell apart.
      module Monophase
        Group = Data.define(:key, :label, :law, :cst, :nature, :prefixes) do
          def fits?(ncm) = prefixes.any? { ncm.to_s.start_with?(_1) }
        end

        GROUPS = [
          Group.new(key: :fuels, label: "combustíveis", law: "Lei 9.718/1998 e Lei 10.336/2001", cst: "04", nature: "001",
            prefixes: %w[27101159 27101259 27101921 27101911 27111910 22071000 220720 38260000]),
          Group.new(key: :pharma, label: "fármacos", law: "Lei 10.147/2000", cst: "04", nature: "002",
            prefixes: %w[3001 3003 3004 3002101 3002102 3002103 3002201 3002202 3006301 3006302 30029020 30029092 30029099 30051010 30066000]),
          Group.new(key: :perfumery, label: "perfumaria, toucador e higiene pessoal", law: "Lei 10.147/2000", cst: "04", nature: "002",
            prefixes: %w[3303 3304 3305 3307 34011190 34012010 96032100]),
          Group.new(key: :vehicles, label: "veículos, máquinas e autopeças", law: "Lei 10.485/2002", cst: "04", nature: "003",
            prefixes: %w[8429 8432 8433 8434 8435 8436 8437 8701 8702 8703 8704 8705 8706 8707 8708 87162000 7309 731029 76129012 842481]),
          Group.new(key: :tyres, label: "pneus e câmaras de ar", law: "Lei 10.485/2002", cst: "04", nature: "003", prefixes: %w[4011 4013]),
          Group.new(key: :drinks, label: "bebidas frias", law: "Lei 13.097/2015", cst: "06", nature: "918",
            prefixes: %w[2106901 2201 2202 2203])
        ].freeze

        module_function

        # The group of an NCM, or nil.
        def for(ncm)
          digits = ncm.to_s.gsub(/\D/, "")
          return if digits.empty?

          GROUPS.find { _1.fits?(digits) }
        end

        # The CSTs a reseller may sell a group's goods with: its own, or 05 (by ST).
        def resale_csts(group) = [group.cst, "05"]
      end
    end
  end
end
