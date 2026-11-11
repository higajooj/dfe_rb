RSpec.describe DfeRb::Efd::Contribuicoes::Note do
  let(:fixtures) { File.expand_path("../../../fixtures/efd", __dir__) }
  let(:analytic) { DfeRb::Efd::Contribuicoes::Analytic }

  context "an NFC-e the informant issued" do
    let(:note) { described_class.new(File.read("#{fixtures}/nfce_contribuicoes.xml"), informant: "12345678000195") }

    it "reads each item's PIS and COFINS" do
      item = note.items.first
      expect(item).to have_attributes(pis_cst: "01", pis_base: BigDecimal("45.65"), pis_rate: BigDecimal("1.65"), pis_value: BigDecimal("0.75"),
        cofins_cst: "01", cofins_rate: BigDecimal("7.6"), cofins_value: BigDecimal("3.47"))
      expect(note.items.last).to have_attributes(pis_cst: "04", pis_base: 0, pis_value: 0)
    end

    it "books C100 with the contributions of its items and no participant, and sums them in C175 by CFOP, CST and rate" do
      c100 = note.c100(period_end: Date.new(2026, 10, 31))
      rows = analytic.c175(note.items, account: "3.1.1.01")

      expect(c100).to include(ind_oper: "1", ind_emit: "0", cod_part: nil, cod_mod: "65", num_doc: 77, vl_doc: 115, vl_merc: 120,
        vl_pis: BigDecimal("1.02"), vl_cofins: BigDecimal("4.73"))
      expect(rows.size).to eq(2)
      expect(rows.first).to eq(cfop: "5102", vl_opr: 80, vl_desc: 5, cst_pis: "01", vl_bc_pis: BigDecimal("62.25"), aliq_pis: BigDecimal("1.65"),
        quant_bc_pis: nil, aliq_pis_quant: nil, vl_pis: BigDecimal("1.02"), cst_cofins: "01", vl_bc_cofins: BigDecimal("62.25"),
        aliq_cofins: BigDecimal("7.6"), quant_bc_cofins: nil, aliq_cofins_quant: nil, vl_cofins: BigDecimal("4.73"), cod_cta: "3.1.1.01")
      expect(rows.last).to include(cfop: "5405", vl_opr: 40, cst_pis: "04", vl_bc_pis: nil, aliq_pis: nil, vl_pis: 0)
    end

    it "writes C175 into a file" do
      file = DfeRb::Efd::Contribuicoes::File.new
      file.add "0000", cod_ver: "006", tipo_escrit: 0, dt_ini: Date.new(2026, 10, 1), dt_fin: Date.new(2026, 10, 31), nome: "EMITENTE LTDA",
        cnpj: "12345678000195", uf: "MS", cod_mun: "5002704", ind_ativ: 2
      c100 = file.add("C010", cnpj: "12345678000195", ind_escri: "2").add("C100", note.c100(period_end: Date.new(2026, 10, 31)))
      analytic.c175(note.items).each { c100.add("C175", _1) }
      lines = file.to_s.split("\r\n")

      expect(lines).to include("|C175|5102|80,00|5,00|01|62,25|1,6500|||1,02|01|62,25|7,6000|||4,73|||", "|C175|5405|40,00|0,00|04|||||0,00|04|||||0,00|||")
      expect(lines.find { _1.start_with?("|C100|") }).to start_with("|C100|1|0||65|00|001|77|50261012345678000195650010000000771000000777|07102026||115,00|0|")
    end
  end

  context "an NF-e received" do
    let(:note) { described_class.new(File.read("#{fixtures}/nfe_sale.xml"), informant: "11222333000181") }

    it "books an item with the credit the informant takes, its value times each rate" do
      item = note.items.first.on_entry(cfop: "2102").contributions(cst: "50", base: 310, pis_rate: "1.65", cofins_rate: "7.6")
      c170 = note.c170(item, cod_item: "CIM50", account: "1.1.3.01")

      expect(c170).to include(cfop: "2102", cst_pis: "50", vl_bc_pis: 310, aliq_pis: BigDecimal("1.65"), vl_pis: BigDecimal("5.12"),
        cst_cofins: "50", vl_bc_cofins: 310, vl_cofins: BigDecimal("23.56"), cod_cta: "1.1.3.01")
      expect(c170).not_to have_key(:vl_abat_nt)
      expect(note.c100(items: [item], participant: "12345678000195", entry_date: Date.new(2026, 10, 8))).to include(ind_oper: "0", ind_emit: "1",
        vl_pis: BigDecimal("5.12"), vl_cofins: BigDecimal("23.56"))
    end

    it "books an item without credit with its CST alone" do
      item = note.items.last.contributions(cst: "70")
      expect(DfeRb::Efd::Contribuicoes::Analytic.contributions(item)).to include(cst_pis: "70", vl_bc_pis: nil, vl_pis: 0, cst_cofins: "70")
    end
  end
end
