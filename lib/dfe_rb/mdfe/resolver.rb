require "base64"
require "digest"
require "time"

module DfeRb
  module Mdfe
    # Completes a manifest. It fills the defaults a developer shouldn't have to spell out and
    # derives what follows from other fields (access key, modal, first and last state,
    # document counts...). Anything the developer set explicitly is kept.
    class Resolver
      # Indicators the layout only takes as 1: a false one is left out.
      FLAGS = %w[indCanalVerde indCarregaPosterior indReentrega indAltoDesemp indAntecipaAdiant].freeze
      DOCUMENTS = {"infCTe" => "qCTe", "infNFe" => "qNFe", "infMDFeTransp" => "qMDFe"}.freeze
      EXTERIOR = "EX"

      # The cMDF and emission time, which must stay the same across resolves of one manifest
      # so that a retry (or the later transmission of one issued in contingency) never
      # produces another key. Held by the Manifest.
      Memo = Struct.new(:numeric_code, :issued_at)

      # Problems that stopped a field from being derived (the access key needs a valid
      # emission date, series and number), as validation messages.
      attr_reader :issues

      # csrt: the Código de Segurança do Responsável Técnico, which signs infRespTec/hashCSRT
      # and never goes into the XML.
      def initialize(environment:, memo:, clock: Time, csrt: nil)
        @environment = Environment.normalize(environment)
        @memo = memo
        @clock = clock
        @csrt = csrt
        @issues = []
      end

      # `infMDFe` (tag-keyed Hash) => a resolved copy.
      def call(infmdfe)
        @issues = []
        inf = Marshal.load(Marshal.dump(infmdfe))
        normalize(inf, Schema.mdfe.find("infMDFe"))
        ide = (inf["ide"] ||= {})
        emit = inf["emit"] || {}
        address(emit["enderEmit"])
        state = emit.dig("enderEmit", "UF")

        cities(ide, inf)
        modal(inf, ide)
        defaults(ide, state)
        carrier_type(inf, ide)
        road(inf, emit)
        totals(inf)
        identify(inf, ide, emit)
        technical_contact(inf)
        inf
      end

      private

      # Formatted codes typed by a person ("11.222.333/0001-81", "abc-1d23") become what the
      # layout takes, and a false indicator is dropped.
      def normalize(data, element)
        element.each_element do |child|
          next unless data.key?(child.tag)

          value = data[child.tag]
          if child.leaf? && child.type
            next data.delete(child.tag) if FLAGS.include?(child.tag) && value.to_s == "0"

            data[child.tag] = value.is_a?(Array) ? value.map { |item| Formatter.forgive(item, child) } : Formatter.forgive(value, child)
          else
            (value.is_a?(Array) ? value : [value]).each { |entry| normalize(entry, child) if entry.is_a?(Hash) }
          end
        end
      end

      # A city code gives its state and name; a name and state give the code (IBGE table).
      def address(address)
        return unless address.is_a?(Hash)

        code = address["cMun"].to_s
        address["UF"] ||= States::CODES.key(code[0, 2].to_i) if code.match?(/\A\d{7}\z/)
        address["xMun"] ||= Cities.name(code) unless code.empty?
        address["cMun"] ||= Cities.code(address["xMun"], address["UF"]) if address["xMun"] && address["UF"]
      end

      # Names for the loading and unloading cities given by code only, and the first and last
      # state of the trip from them.
      def cities(ide, inf)
        loading = Array(ide["infMunCarrega"])
        unloading = Array(inf.dig("infDoc", "infMunDescarga"))
        loading.each { |city| city["xMunCarrega"] ||= Cities.name(city["cMunCarrega"]) }
        unloading.each { |city| city["xMunDescarga"] ||= Cities.name(city["cMunDescarga"]) }
        ide["UFIni"] ||= state_of(loading.first&.[]("cMunCarrega"))
        ide["UFFim"] ||= state_of(unloading.first&.[]("cMunDescarga"))
      end

      def state_of(city_code)
        code = city_code.to_s
        return unless code.match?(/\A\d{7}\z/)

        code.start_with?("99") ? EXTERIOR : States::CODES.key(code[0, 2].to_i)
      end

      # The modal filled in says which one the manifest is.
      def modal(inf, ide)
        group = inf["infModal"] or return
        given = Schema::MODALS.keys.select { |tag| group[tag] }
        return unless given.size == 1

        ide["modal"] ||= Schema::MODALS.fetch(given.first).last
        group["@versaoModal"] ||= Schema::VERSION
      end

      def defaults(ide, state)
        ide["cUF"] ||= States.code(state) if state && States::CODES.key?(state)
        ide["tpAmb"] ||= Environment.code(@environment)
        ide["mod"] ||= AccessKey::MODEL
        ide["serie"] ||= 1
        ide["tpEmis"] ||= 1
        ide["procEmi"] ||= 0
        ide["verProc"] ||= "dfe_rb #{DfeRb::VERSION}"
        # A copy, so nothing done to the tree can change the memoized time.
        ide["dhEmi"] ||= (@memo.issued_at ||= now_in(state)).dup
        ide["dhEmi"] = ide["dhEmi"].to_time if ide["dhEmi"].is_a?(DateTime)
        ide["dhIniViagem"] = ide["dhIniViagem"].to_time if ide["dhIniViagem"].is_a?(DateTime)
        ide["cMDF"] ||= (@memo.numeric_code ||= AccessKey.generate_numeric_code(number: ide["nMDF"]))
      end

      def now_in(state)
        (state && States::CODES.key?(state)) ? States.now(state, @clock) : @clock.now.getlocal(States::DEFAULT_UTC_OFFSET)
      end

      # The traction vehicle's owner says what kind of carrier hauls it: a person is a TAC
      # (F18), a company an ETC unless told it is a CTC (F19).
      def carrier_type(inf, ide)
        owner = inf.dig("infModal", "rodo", "veicTracao", "prop") or return

        ide["tpTransp"] ||= if owner["CPF"]
          2
        elsif owner["CNPJ"]
          1
        end
      end

      # With an owner on the traction vehicle, the one who contracted the transport is the
      # issuer (F65). Installments are numbered 001, 002... (F59).
      def road(inf, emit)
        rodo = inf.dig("infModal", "rodo") or return

        issuer = emit.slice("CNPJ", "CPF")
        if rodo.dig("veicTracao", "prop") && !issuer.empty?
          antt = (rodo["infANTT"] ||= {})
          antt["infContratante"] = [issuer] if Array(antt["infContratante"]).empty?
        end
        Array(rodo.dig("infANTT", "infPag")).each do |payment|
          Array(payment["infPrazo"]).each_with_index { |installment, index| installment["nParcela"] ||= format("%03d", index + 1) }
        end
      end

      # How many documents of each kind the manifest carries (F51), and kilograms unless told.
      def totals(inf)
        tot = (inf["tot"] ||= {})
        cities = Array(inf.dig("infDoc", "infMunDescarga"))
        DOCUMENTS.each do |group, counter|
          count = cities.sum { |city| Array(city[group]).size }
          tot[counter] ||= count if count.positive?
        end
        tot["cUnid"] ||= "01"
      end

      def identify(inf, ide, emit)
        tax_id = emit["CNPJ"] || emit["CPF"]
        return unless tax_id && ide["cUF"] && ide["nMDF"] && ide["dhEmi"]

        issued_at = issued_time(ide["dhEmi"])
        return unless key_parts_valid?(ide, issued_at)

        key = AccessKey.build(state: ide["cUF"], issued_at: issued_at, tax_id: tax_id, series: ide["serie"].to_i,
          number: ide["nMDF"].to_i, numeric_code: ide["cMDF"], model: ide["mod"].to_i, emission_type: ide["tpEmis"].to_i)
        ide["cDV"] = key.check_digit
        inf["@Id"] = key.id
        inf["@versao"] = Schema::VERSION
      rescue ArgumentError => e
        @issues << "cannot build the access key: #{e.message}"
      end

      # The key has fixed-width positions, so values that don't fit are reported instead of
      # producing a malformed key.
      def key_parts_valid?(ide, issued_at)
        problems = []
        problems << "ide/dhEmi: #{ide["dhEmi"].inspect} is not a date and time (e.g. 2026-09-29T10:00:00-03:00)" unless issued_at
        problems << "ide/serie: #{ide["serie"]} is not a series (0 to 999)" unless digits?(ide["serie"], 0..999)
        problems << "ide/nMDF: #{ide["nMDF"]} is not a manifest number (1 to 999999999)" unless digits?(ide["nMDF"], 1..999_999_999)
        problems << "ide/cMDF: #{ide["cMDF"]} is not an 8-digit numeric code" unless ide["cMDF"].to_s.match?(/\A\d{1,8}\z/)
        problems << "ide/tpEmis: #{ide["tpEmis"]} is not an emission type (1 to 3)" unless digits?(ide["tpEmis"], 1..3)
        problems << "ide/mod: #{ide["mod"]} is not the MDF-e's model (58)" unless ide["mod"].to_s == AccessKey::MODEL.to_s
        @issues.concat(problems)
        problems.empty?
      end

      def digits?(value, range) = value.to_s.match?(/\A\d+\z/) && range.cover?(value.to_i)

      def issued_time(value)
        return value.to_time if value.is_a?(DateTime)
        return value if value.respond_to?(:strftime)

        Time.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end

      # hashCSRT = Base64(SHA-1(CSRT + chave de acesso)).
      def technical_contact(inf)
        contact = inf["infRespTec"]
        return unless @csrt && contact && inf["@Id"]

        contact["hashCSRT"] ||= Base64.strict_encode64(Digest::SHA1.digest("#{@csrt}#{inf["@Id"].delete_prefix("MDFe")}"))
      end
    end
  end
end
