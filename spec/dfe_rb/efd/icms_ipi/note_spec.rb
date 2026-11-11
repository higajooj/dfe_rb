RSpec.describe DfeRb::Efd::IcmsIpi::Note do
  let(:xml) { File.read(File.expand_path("../../../fixtures/efd/nfe_sale.xml", __dir__)) }
  let(:analytic) { DfeRb::Efd::IcmsIpi::Analytic }

  context "issued by the informant" do
    let(:note) { described_class.new(xml, informant: "12.345.678/0001-95") }

    it "books a sale going out: C100 with the totals of its C190, and C101 for the DIFAL" do
      c100 = note.c100(participant: "11222333000181", period_end: Date.new(2026, 10, 31))

      expect(c100).to include(ind_oper: "1", ind_emit: "0", cod_part: "11222333000181", cod_mod: "55", cod_sit: "00", ser: "001", num_doc: 1234,
        chv_nfe: "50261012345678000195550010000012341000012345", dt_doc: Date.new(2026, 10, 5), dt_e_s: Date.new(2026, 10, 6),
        vl_doc: BigDecimal("654.70"), ind_pgto: "1", vl_desc: 10, vl_merc: 600, ind_frt: "0", vl_frt: 20, vl_bc_icms: 560, vl_icms: BigDecimal("67.2"),
        vl_bc_icms_st: 280, vl_icms_st: BigDecimal("29.2"), vl_ipi: BigDecimal("15.5"), vl_pis: BigDecimal("3.9"))
      expect(note.c101).to eq(vl_fcp_uf_dest: 4, vl_icms_uf_dest: 24, vl_icms_uf_rem: 0)
      expect(note.counterparty_uf).to eq("SP")
    end

    it "sums its items by CST, CFOP and rate, whose operation values make up the note's total" do
      rows = analytic.c190(note.items)

      expect(rows.map { |r| r.values_at(:cst_icms, :cfop, :aliq_icms) }).to eq([["000", "6102", 12], ["010", "6403", 12], ["020", "6102", 12]])
      expect(rows[0]).to include(vl_opr: BigDecimal("325.5"), vl_bc_icms: 310, vl_icms: BigDecimal("37.2"), vl_ipi: BigDecimal("15.5"))
      expect(rows[1]).to include(vl_opr: BigDecimal("229.2"), vl_bc_icms_st: 280, vl_icms_st: BigDecimal("29.2"))
      expect(rows[2]).to include(vl_opr: 100, vl_bc_icms: 50, vl_red_bc: 50)
      expect(rows.sum { |r| r[:vl_opr] }).to eq(note.total)
    end

    it "reduces a canceled note to its identity" do
      expect(note.c100(situation: "02")).to eq(ind_oper: "1", ind_emit: "0", cod_mod: "55", cod_sit: "02", ser: "001", num_doc: 1234,
        chv_nfe: "50261012345678000195550010000012341000012345")
    end
  end

  context "received" do
    let(:note) { described_class.new(xml, informant: "11222333000181") }

    it "comes in from its issuer, the participant" do
      expect(note).not_to be_own
      expect(note.operation).to eq("0")
      expect(note.participant).to include(cod_part: "12345678000195", nome: "EMITENTE LTDA", cod_pais: "01058", ie: "283456789", cod_mun: "5002704")
    end

    it "books what the recipient credits, the IPI and ST it can't credit in the goods' value" do
      items = note.items.map { |i| i.on_entry(cfop: "2#{i.cfop[1..]}", icms_credit: (i.cst == "10") ? 0 : i.icms_value) }
      c100 = note.c100(items:, participant: "12345678000195", entry_date: Date.new(2026, 10, 8))
      rows = analytic.c190(items)

      expect(c100).to include(dt_e_s: Date.new(2026, 10, 8), vl_merc: BigDecimal("644.7"), vl_ipi: 0, vl_icms_st: 0, vl_icms: BigDecimal("43.2"), vl_pis: nil)
      expect(rows.map { |r| r.values_at(:cst_icms, :cfop, :aliq_icms) }).to eq([["000", "2102", 12], ["020", "2102", 12], ["060", "2403", 0]])
      expect(rows.sum { |r| r[:vl_opr] }).to eq(note.total)
      expect(note.c170(items.first, cod_item: "P1", unit: "UN", quantity: 500)).to include(num_item: 1, cod_item: "P1", qtd: 500, unid: "UN",
        vl_item: BigDecimal("315.5"), cst_icms: "000", cfop: "2102", vl_icms: BigDecimal("37.2"), vl_ipi: 0, ind_mov: "0")
    end

    it "books what it takes no credit on as CST 90 with no reduced base, and the IPI by the entry's CST" do
      item = note.items.find { |i| i.cst == "20" }.on_entry(cfop: "2102")
      rows = analytic.c190([item])

      expect(rows.size).to eq(1)
      expect(rows.first).to include(cst_icms: "090", vl_red_bc: 0, vl_icms: 0)
      expect(note.items.first.on_entry(cfop: "2102", ipi_credit: true)).to have_attributes(ipi_cst: "00", ipi_value: BigDecimal("15.5"))
      expect(note.items.first.on_entry(cfop: "2102")).to have_attributes(ipi_cst: "49", ipi_value: 0)
      expect(note.items.last.on_entry(cfop: "2410", st_credit: true)).to have_attributes(cst_icms: "010", st_value: BigDecimal("29.2"))
    end

    it "takes a Simples Nacional supplier's note as CST 90, or 60 with ST, its credit on the goods" do
      item = DfeRb::Efd::IcmsIpi::Item.new(origin: "0", csosn: "101", value: 100, simples_credit_rate: 2.5, simples_credit_value: 2.5)

      expect(item.on_entry(cfop: "1102", icms_credit: 2.5)).to have_attributes(cst_icms: "090", icms_base: 100, icms_rate: 2.5, icms_value: 2.5)
      expect(item.with(csosn: "500").on_entry(cfop: "1403").cst_icms).to eq("060")
    end
  end
end
