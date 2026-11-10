require "nokogiri"

module DfeRb
  module Efd
    module IcmsIpi
      # An NF-e (modelo 55) or NFC-e (65), its nfeProc as SEFAZ authorized it, as the
      # informant (the CNPJ the file is of) books it in Block C: who issued it, which way
      # it goes, its participant (0150), its items with their taxes, and the C100 and
      # C101 that carry it.
      #
      #   note = Note.new(xml, informant: "12345678000195")
      #   items = note.items
      #   items = items.map { it.on_entry(cfop: "1102", icms_credit: 18) } unless note.own?
      #   c100 = file.add("C100", note.c100(items:, participant: note.participant[:cod_part], entry_date:))
      #   Analytic.c190(items).each { c100.add("C190", it) }
      class Note
        # cStat of an nfeProc that authorizes a note, in time or late.
        AUTHORIZED = %w[100 150].freeze
        # The situations (COD_SIT) whose C100 is reduced to the document's identity, with no children.
        REDUCED = %w[02 03 04 05].freeze
        BRAZIL = "1058"

        attr_reader :informant

        def initialize(xml, informant:)
          @doc = Nokogiri::XML(xml)
          @doc.remove_namespaces!
          @informant = informant.to_s.gsub(/\D/, "")
          raise ArgumentError, "not an NF-e" unless inf
        end

        def key = value(@doc.at_css("protNFe infProt chNFe")) || inf["Id"].to_s.delete_prefix("NFe")

        def number = text("ide nNF").to_i

        def series = text("ide serie").to_i

        # COD_MOD: "55" or "65".
        def model = text("ide mod")

        def nfce? = model == "65"

        def issued_on = date(text("ide dhEmi"))

        # When the goods left or came in, as the issuer gave it (dhSaiEnt), else nil.
        def moved_on = date(text("ide dhSaiEnt"))

        def emitter_tax_id = text("emit CNPJ") || text("emit CPF")

        def recipient_tax_id = text("dest CNPJ") || text("dest CPF")

        # Issued by the informant itself (IND_EMIT 0).
        def own? = emitter_tax_id == informant

        # IND_OPER: a note the informant issued goes out (1) or comes in (0) by its tpNF;
        # one issued by someone else always comes in.
        def operation = (own? && text("ide tpNF") == "1") ? "1" : "0"

        def outbound? = operation == "1"

        # The state of the other side: where the goods go, for a note going out, or come from.
        def counterparty_uf = text("#{counterparty_group} #{address_group} UF")

        def total = number_at("total ICMSTot vNF")

        # The participant (0150) of the other side of the note; nil for an NFC-e, which
        # names none in the file.
        def participant
          return if nfce?

          group = counterparty_group
          return unless @doc.at_css("infNFe #{group}")

          country = text("#{group} #{address_group} cPais") || BRAZIL
          foreign = country != BRAZIL
          cnpj = text("#{group} CNPJ")
          cpf = text("#{group} CPF")
          ie = text("#{group} IE")
          {
            cod_part: cnpj || cpf || "EX#{text("#{group} idEstrangeiro") || key}",
            nome: text("#{group} xNome"), cod_pais: country.rjust(5, "0"),
            cnpj: (cnpj unless foreign), cpf: (cpf unless foreign), ie: (ie if ie&.match?(/\A\d+\z/)),
            cod_mun: (text("#{group} #{address_group} cMun") unless foreign), suframa: text("#{group} ISUF"),
            end: text("#{group} #{address_group} xLgr"), num: text("#{group} #{address_group} nro"),
            compl: text("#{group} #{address_group} xCpl"), bairro: text("#{group} #{address_group} xBairro")
          }
        end

        # Its items as the document carries them.
        def items = @items ||= @doc.css("infNFe det").map { |det| Item.from(det) }

        # The C100 of the note in a situation (COD_SIT): the identity alone for a canceled,
        # denied or voided one; else its values, the taxes summed from its items (as booked:
        # Item#on_entry), the participant's code (none for an NFC-e) and, coming in, the day
        # it came in (DT_E_S, required then).
        def c100(situation: "00", items: self.items, participant: nil, entry_date: nil)
          head = {ind_oper: operation, ind_emit: own? ? "0" : "1", cod_mod: model, cod_sit: situation,
                  ser: series.to_s.rjust(3, "0"), num_doc: number, chv_nfe: key}
          return head if REDUCED.include?(situation)

          sums = Analytic.totals(items)
          values = head.merge(
            cod_part: (participant unless nfce?), dt_doc: issued_on, dt_e_s: outbound? ? moved_on_within(entry_date) : (entry_date || issued_on),
            vl_doc: total, ind_pgto: payment_indicator, vl_desc: sums[:discount], vl_abat_nt: 0, vl_merc: sums[:value], ind_frt: freight_indicator,
            vl_frt: sums[:freight], vl_seg: sums[:insurance], vl_out_da: sums[:other], vl_bc_icms: sums[:icms_base], vl_icms: sums[:icms_value]
          )
          return values if nfce?

          values.merge(vl_bc_icms_st: sums[:st_base], vl_icms_st: sums[:st_value], vl_ipi: sums[:ipi_value],
            vl_pis: (number_at("total ICMSTot vPIS") if outbound?), vl_cofins: (number_at("total ICMSTot vCOFINS") if outbound?))
        end

        # The DIFAL and FCP of a sale to a consumer in another state (C101, EC 87/15), when the note has them.
        def c101
          fcp = number_at("total ICMSTot vFCPUFDest")
          dest = number_at("total ICMSTot vICMSUFDest")
          rem = number_at("total ICMSTot vICMSUFRemet")
          return if [fcp, dest, rem].all?(&:zero?)

          {vl_fcp_uf_dest: fcp, vl_icms_uf_dest: dest, vl_icms_uf_rem: rem}
        end

        # C170 of an item, in the informant's code and unit (COD_ITEM of its 0200, and the
        # quantity in that unit when it converts the document's), coming in: what the
        # informant books of a note received.
        def c170(item, cod_item:, unit: item.unit, quantity: item.quantity, moved: true)
          {
            num_item: item.number, cod_item:, descr_compl: item.description, qtd: quantity, unid: unit, vl_item: item.value,
            vl_desc: item.discount, ind_mov: moved ? "0" : "1", cst_icms: item.cst_icms, cfop: item.cfop,
            vl_bc_icms: item.icms_base, aliq_icms: item.icms_rate, vl_icms: item.icms_value,
            vl_bc_icms_st: item.st_base, aliq_st: item.st_rate, vl_icms_st: item.st_value,
            ind_apur: (item.ipi_value.positive? ? "0" : nil), cst_ipi: (item.ipi_cst if item.ipi_value.positive?),
            vl_bc_ipi: item.ipi_base, aliq_ipi: item.ipi_rate, vl_ipi: item.ipi_value, vl_abat_nt: 0
          }
        end

        private

        def inf = @doc.at_css("infNFe")

        def text(path) = value(@doc.at_css("infNFe #{path}"))

        def value(node) = node&.text&.strip.then { |t| t unless t.nil? || t.empty? }

        def number_at(path) = BigDecimal(text(path) || "0")

        def date(value) = value && Date.strptime(value[0, 10], "%Y-%m-%d")

        # Of the other side: the recipient of a note the informant issued, else the issuer.
        def counterparty_group = own? ? "dest" : "emit"

        def address_group = own? ? "enderDest" : "enderEmit"

        # Going out, the day it left only when it falls within the period: nil otherwise.
        def moved_on_within(last_day)
          day = moved_on
          day if day && (last_day.nil? || day <= last_day) && day >= issued_on
        end

        # IND_PGTO: on credit (1) when anything is paid in installments, nothing paid (2) by
        # tPag 90, else at sight (0).
        def payment_indicator
          return "1" if @doc.at_css("infNFe cobr dup") || @doc.css("infNFe pag detPag indPag").any? { |n| n.text == "1" }
          return "2" if @doc.css("infNFe pag detPag tPag").map(&:text).uniq == ["90"]

          "0"
        end

        # IND_FRT: the NF-e's modFrete, the same codes since 2018.
        def freight_indicator = text("transp modFrete") || "9"
      end
    end
  end
end
