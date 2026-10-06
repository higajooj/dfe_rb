module DfeRb
  module Nfe
    # The Evento Prévio de Emissão em Contingência (110140, NT 2014.001): a summary of a note
    # issued with tpEmis 4, registered at the Ambiente Nacional while the issuer can't reach
    # its SEFAZ. Everything in it is read from the signed note, which SEFAZ later compares
    # with it (RV 2AB08-30).
    module Epec
      TYPE = "110140"
      EMISSION_TYPE = "4"
      # cOrgao of the Ambiente Nacional, which registers it.
      AGENCY = "91"
      # tpAutor: the issuer itself.
      AUTHOR = "1"

      module_function

      # The unsigned <evento> for `document` (a Document of the signed note).
      def build(document, environment:, clock: Time)
        inf = document.to_infnfe
        ide = inf["ide"] || {}
        emit = inf["emit"] || {}
        state = emit.dig("enderEmit", "UF")
        check(ide, emit, state)

        key = AccessKey.parse(document.key)
        Requests.event(key: key, type: TYPE, sequence: 1, detail: detail(inf, ide, emit, key), environment: environment,
          at: States.now(key.state, clock), agency: AGENCY)
      end

      def check(ide, emit, state)
        problems = []
        problems << "ide/tpEmis: an EPEC is for a note issued with tpEmis 4 (got #{ide["tpEmis"]})" unless ide["tpEmis"].to_s == EMISSION_TYPE
        problems << "ide/mod: an EPEC is for NF-e modelo 55" unless ide["mod"].to_s == "55"
        problems << "emit/IE: the EPEC carries the issuer's state registration" if emit["IE"].to_s.empty?
        if States::EPEC_BARRED.include?(state)
          problems << "emit/enderEmit/UF: taxpayers of #{state} can't register an EPEC (Ajuste SINIEF 25/2026, RV 2P10-20)"
        end
        raise ValidationError, problems unless problems.empty?
      end

      def detail(inf, ide, emit, key)
        totals = inf.dig("total", "ICMSTot") || {}
        %(<descEvento>EPEC</descEvento><cOrgaoAutor>#{key.state_code}</cOrgaoAutor><tpAutor>#{AUTHOR}</tpAutor>) +
          %(<verAplic>#{Requests.escape(ide["verProc"].to_s[0, 20])}</verAplic><dhEmi>#{ide["dhEmi"]}</dhEmi>) +
          %(<tpNF>#{ide["tpNF"]}</tpNF><IE>#{emit["IE"]}</IE>#{recipient(inf["dest"] || {}, totals)})
      end

      # The recipient's state and identity (an empty idEstrangeiro stands, as in the note),
      # then the note's totals: the event's schema keeps them inside <dest>, though the NT's
      # table lists them beside it.
      def recipient(dest, totals)
        tag = %w[CNPJ CPF idEstrangeiro].find { |name| dest.key?(name) }
        identity = tag ? "<#{tag}>#{Requests.escape(dest[tag])}</#{tag}>" : ""
        registration = dest["IE"].to_s.empty? ? "" : "<IE>#{dest["IE"]}</IE>"
        %(<dest><UF>#{dest.dig("enderDest", "UF")}</UF>#{identity}#{registration}) +
          %(<vNF>#{totals["vNF"]}</vNF><vICMS>#{totals["vICMS"]}</vICMS><vST>#{totals["vST"]}</vST></dest>)
      end
    end
  end
end
