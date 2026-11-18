module DfeRb
  module Nfse
    # Completes a DPS. It fills the defaults a developer shouldn't have to spell out and
    # derives what follows from other fields (the Id, the dates, the IBS/CBS indicators).
    # Anything the developer set explicitly is kept.
    class Resolver
      ISSUER_GROUPS = {"1" => "prest", "2" => "toma", "3" => "interm"}.freeze
      MEI = "2"

      # The emission time, which must stay the same across resolves of one declaration so a
      # retry sends the same document. Held by the Declaration.
      Memo = Struct.new(:issued_at)

      # Problems that stopped a field from being derived, as validation messages.
      attr_reader :issues

      def initialize(environment:, layout:, memo:, clock: Time)
        @environment = Environment.normalize(environment)
        @layout = layout
        @memo = memo
        @clock = clock
        @issues = []
      end

      # `infDPS` (tag-keyed Hash) => a resolved copy.
      def call(infdps)
        @issues = []
        inf = Marshal.load(Marshal.dump(infdps))
        normalize(inf, @layout.dps.find("infDPS"))
        inf["tpAmb"] ||= Environment.code(@environment)
        inf["verAplic"] ||= "dfe_rb #{DfeRb::VERSION}"
        inf["serie"] ||= 1
        inf["tpEmit"] ||= 1
        dates(inf)
        purpose(inf)
        ibs_cbs(inf)
        approximate_taxes(inf)
        identify(inf)
        inf
      end

      # The DPS Id: "DPS" + cLocEmi (7) + 1 for a CPF or 2 for a CNPJ + the issuer's CPF or
      # CNPJ (14, a CPF with zeros on the left) + serie (5) + nDPS (15) (TSIdDPS, E0004). The
      # issuer is whom tpEmit names. Nil when a part is missing or malformed.
      def self.id(city:, tax_id:, series:, number:)
        return unless city.to_s.match?(/\A\d{7}\z/) && series.to_s.match?(/\A\d{1,5}\z/) && number.to_s.match?(/\A\d{1,15}\z/)

        id = TaxId.normalize(tax_id)
        kind = if TaxId::CPF_FORMAT.match?(id)
          "1"
        elsif TaxId::CNPJ_FORMAT.match?(id)
          "2"
        end
        return unless kind

        "DPS#{city}#{kind}#{id.rjust(14, "0")}#{series.to_s.rjust(5, "0")}#{number.to_s.rjust(15, "0")}"
      end

      private

      # Formatted codes typed by a person ("11.222.333/0001-81", "79170-000") become what
      # the layout takes.
      def normalize(data, element)
        element.each_element do |child|
          next unless data.key?(child.tag)

          value = data[child.tag]
          if child.leaf? && child.type
            data[child.tag] = value.is_a?(Array) ? value.map { |item| Formatter.forgive(item, child) } : Formatter.forgive(value, child)
          else
            (value.is_a?(Array) ? value : [value]).each { |entry| normalize(entry, child) if entry.is_a?(Hash) }
          end
        end
      end

      # dhEmi now, in the offset of the issuing city's state; dCompet its day.
      def dates(inf)
        city = inf["cLocEmi"].to_s
        state = States::CODES.key(city[0, 2].to_i) if city.match?(/\A\d{7}\z/)
        @memo.issued_at ||= state ? States.now(state, @clock) : @clock.now.getlocal(States::DEFAULT_UTC_OFFSET)
        inf["dhEmi"] ||= @memo.issued_at
        issued = inf["dhEmi"]
        inf["dCompet"] ||= issued.respond_to?(:to_date) ? issued.to_date : Date.parse(issued.to_s)
      rescue Date::Error
        nil
      end

      # finNFSe 0, the only one the layouts take: in infDPS under NT 009, in IBSCBS before it.
      def purpose(inf)
        if @layout.dps.find("infDPS").find("finNFSe")
          inf["finNFSe"] ||= 0
        elsif inf["IBSCBS"].is_a?(Hash)
          inf["IBSCBS"]["finNFSe"] ||= 0
        end
      end

      # indDest says whether the IBS/CBS recipient is someone else than the taker: it is
      # when a recipient (dest) is given.
      def ibs_cbs(inf)
        group = inf["IBSCBS"]
        return unless group.is_a?(Hash)

        group["indDest"] ||= group["dest"] ? 1 : 0
      end

      # A MEI informs no approximate taxes unless it chooses to (indTotTrib 0).
      def approximate_taxes(inf)
        regime = inf.dig("prest", "regTrib", "opSimpNac").to_s
        trib = (inf["valores"] ||= {})["trib"] ||= {}
        trib["totTrib"] ||= {"indTotTrib" => 0} if regime == MEI
      end

      def identify(inf)
        return if inf["@Id"]

        group = ISSUER_GROUPS[inf["tpEmit"].to_s]
        party = (group && inf[group]) || {}
        tax_id = party["CNPJ"] || party["CPF"]
        id = self.class.id(city: inf["cLocEmi"], tax_id: tax_id, series: inf["serie"], number: inf["nDPS"])
        if id
          inf["@Id"] = id
        else
          @issues << "cannot build the DPS Id yet: fill in the issuing city (city), the #{party_name(group)}'s CNPJ or CPF, " \
            "the series and the number (E0004)"
        end
      end

      def party_name(group) = {"prest" => "provider", "toma" => "taker", "interm" => "intermediary"}.fetch(group, "issuer")
    end
  end
end
