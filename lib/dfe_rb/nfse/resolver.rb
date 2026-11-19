module DfeRb
  module Nfse
    # Completes a DPS. It fills the defaults a developer shouldn't have to spell out and
    # derives what follows from other fields (the Id, the dates, the IBS/CBS indicators).
    # Anything the developer set explicitly is kept.
    class Resolver
      ISSUER_GROUPS = {"1" => "prest", "2" => "toma", "3" => "interm"}.freeze
      MEI = "2"

      Emission = Struct.new(:issued_at)

      attr_reader :issues

      def initialize(environment:, layout:, emission:, clock: Time)
        @environment = Environment.normalize(environment)
        @layout = layout
        @emission = emission
        @clock = clock
        @issues = []
      end

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
        recipient_indicator(inf)
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

      def dates(inf)
        @emission.issued_at ||= Nfse.local_time(inf["cLocEmi"], @clock)
        inf["dhEmi"] ||= @emission.issued_at
        issued = inf["dhEmi"]
        inf["dCompet"] ||= issued.respond_to?(:to_date) ? issued.to_date : Date.parse(issued.to_s)
      rescue Date::Error
        nil
      end

      def purpose(inf)
        if @layout.dps.find("infDPS").find("finNFSe")
          inf["finNFSe"] ||= 0
        elsif inf["IBSCBS"].is_a?(Hash)
          inf["IBSCBS"]["finNFSe"] ||= 0
        end
      end

      def recipient_indicator(inf)
        group = inf["IBSCBS"]
        return unless group.is_a?(Hash)

        group["indDest"] ||= group["dest"] ? 1 : 0
      end

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
