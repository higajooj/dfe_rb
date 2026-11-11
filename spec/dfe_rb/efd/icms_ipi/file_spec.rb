RSpec.describe DfeRb::Efd::IcmsIpi::File do
  let(:file) { described_class.new }

  def opening
    file.add "0000", cod_ver: "020", cod_fin: 0, dt_ini: Date.new(2026, 10, 1), dt_fin: Date.new(2026, 10, 31), nome: "EMITENTE LTDA",
      cnpj: "12345678000195", uf: "MS", ie: "283456789", cod_mun: "5002704", ind_perfil: "A", ind_ativ: 1
  end

  it "opens and closes every block, empty ones without data, and counts the lines in Block 9" do
    opening
    file.add "0005", fantasia: "EMITENTE", cep: "79002000", end: "Rua A", bairro: "Centro"
    lines = file.to_s.split("\r\n")

    expect(lines.first).to eq("|0000|020|0|01102026|31102026|EMITENTE LTDA|12345678000195||MS|283456789|5002704|||A|1|")
    expect(lines[1]).to eq("|0001|0|")
    expect(lines[3]).to eq("|0990|4|")
    expect(lines).to include("|B001|1|", "|B990|2|", "|C001|1|", "|C990|2|", "|H001|1|", "|K001|1|", "|1001|1|")
    expect(lines).to include("|9900|0000|1|", "|9900|9900|#{lines.count { |l| l.start_with?("|9900|") }}|")
    expect(lines.last).to eq("|9999|#{lines.size}|")
    nine = lines.drop_while { |l| !l.start_with?("|9001|") }
    expect(lines[-2]).to eq("|9990|#{nine.size}|")
    expect(file.to_s).to end_with("\r\n")
  end

  it "writes blocks in their order and registers by code under their parents" do
    opening
    c100 = file.add "C100", ind_oper: "1", ind_emit: "0", cod_mod: "55", cod_sit: "02", ser: "001", num_doc: 7, chv_nfe: "5" * 44
    c100.add "C190", cst_icms: "000", cfop: "5102", aliq_icms: 18, vl_opr: 1, vl_bc_icms: 1, vl_icms: 0.18, vl_bc_icms_st: 0,
      vl_icms_st: 0, vl_red_bc: 0, vl_ipi: 0
    c100.add "C101", vl_fcp_uf_dest: 0, vl_icms_uf_dest: 1, vl_icms_uf_rem: 0
    file.add "0150", cod_part: "X", nome: "X", cod_pais: "01058", end: "Rua"
    codes = file.lines.map(&:code)

    expect(codes.index("0150")).to be < codes.index("0990")
    expect(codes.each_cons(3).to_a).to include(%w[C100 C101 C190])
    expect(file.records("C001").first[:ind_mov]).to eq(0)
    expect(file.counts["C190"]).to eq(1)
  end

  it "writes decimals with a comma, dates as ddmmaaaa and text without pipes, in ISO-8859-1" do
    opening
    file.add "0200", cod_item: "A|1", descr_item: "Pá “reforçada” — 1ª", unid_inv: "UN", tipo_item: 0, aliq_icms: BigDecimal("17.5")
    line = file.to_s.lines.find { |l| l.start_with?("|0200|") }

    expect(line).to eq("|0200|A 1|Pá \"reforçada\" - 1ª|||UN|00|||||17,50||\r\n")
    expect(file.to_latin1.encoding).to eq(Encoding::ISO_8859_1)
  end

  it "refuses what the layout doesn't take, naming each problem" do
    opening
    file.add "0150", cod_part: "1", nome: "", cod_pais: "1058", cnpj: "123", end: "Rua"

    expect { file.to_s }.to raise_error(DfeRb::ValidationError) { |e|
      expect(e.issues).to contain_exactly("0150 NOME is required", "0150 CNPJ must have 14 characters (123)")
    }
    expect { file.add("C190") }.to raise_error(ArgumentError, "C190 goes under C100")
    expect { file.add("C001") }.to raise_error(ArgumentError, /written by the file/)
    expect { file.add("0005", nope: 1) }.to raise_error(ArgumentError, "0005 has no field NOPE")
  end

  it "needs its 0000" do
    expect { file.to_s }.to raise_error(ArgumentError, /0000/)
  end
end
