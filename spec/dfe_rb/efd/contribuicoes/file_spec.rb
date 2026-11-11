RSpec.describe DfeRb::Efd::Contribuicoes::File do
  let(:file) { described_class.new }
  let(:efd) { DfeRb::Efd::Contribuicoes }

  def opening
    file.add "0000", cod_ver: efd::Version.for(Date.new(2026, 10, 31)), tipo_escrit: 0, dt_ini: Date.new(2026, 10, 1), dt_fin: Date.new(2026, 10, 31),
      nome: "EMITENTE LTDA", cnpj: "12345678000195", uf: "MS", cod_mun: "5002704", ind_nat_pj: "00", ind_ativ: 2
  end

  it "opens and closes the blocks of the EFD-Contribuições, empty ones without data, and counts the lines in Block 9" do
    opening
    file.add "0110", cod_inc_trib: 1, ind_apro_cred: 1, cod_tipo_cont: 1
    lines = file.to_s.split("\r\n")

    expect(lines.first).to eq("|0000|006|0|||01102026|31102026|EMITENTE LTDA|12345678000195|MS|5002704||00|2|")
    expect(lines.map { _1[1, 4] }.select { _1.end_with?("001") }).to eq(%w[0001 A001 C001 D001 F001 I001 M001 P001 1001 9001])
    expect(lines).to include("|0110|1|1|1||", "|A001|1|", "|C001|1|", "|M001|1|", "|P990|2|", "|1001|1|")
    expect(lines.last).to eq("|9999|#{lines.size}|")
  end

  it "keeps an establishment's participants, units and items below its 0140, and the notes below its C010" do
    opening
    establishment = file.add "0140", nome: "EMITENTE LTDA", cnpj: "12345678000195", uf: "MS", cod_mun: "5002704"
    establishment.add "0200", cod_item: "CIM50", descr_item: "Cimento", unid_inv: "SC", tipo_item: "00"
    establishment.add "0150", cod_part: "11222333000181", nome: "Cliente", cod_pais: "01058"
    establishment.add "0190", unid: "SC", descr: "Saco"
    file.add "0100", nome: "Contador", cpf: "52998224725", crc: "MS012345O1"
    file.add "C010", cnpj: "12345678000195", ind_escri: "2"
    codes = file.lines.map(&:code)

    expect(codes.first(8)).to eq(%w[0000 0001 0100 0140 0150 0190 0200 0990])
    expect(codes).to include("C010")
    expect(file.records("C001").first[:ind_mov]).to eq(0)
  end

  it "has no leiaute before 2020 or after PIS and COFINS end" do
    expect(efd::Version.for(Date.new(2021, 1, 31))).to eq("006")
    expect { efd::Version.for(Date.new(2019, 12, 31)) }.to raise_error(ArgumentError, /2020/)
    expect { efd::Version.for(Date.new(2027, 1, 31)) }.to raise_error(ArgumentError, /31\/12\/2026/)
  end

  it "refuses a register under the wrong parent" do
    opening
    expect { file.add "0150", cod_part: "X" }.to raise_error(ArgumentError, /goes under 0140/)
    expect { file.add("C010", cnpj: "12345678000195").add("C170", num_item: 1) }.to raise_error(ArgumentError, /doesn't go under C010/)
  end

  it "groups the monophase goods by NCM, with what a reseller books them as" do
    expect(efd::Monophase.for("4011.40.00")).to have_attributes(key: :tyres, cst: "04", nature: "003")
    expect(efd::Monophase.for("30049099")).to have_attributes(key: :pharma, nature: "002")
    expect(efd::Monophase.for("22021000")).to have_attributes(cst: "06", nature: "918")
    expect(efd::Monophase.for("25232910")).to be_nil
    expect(efd::Monophase.for(nil)).to be_nil
  end
end
