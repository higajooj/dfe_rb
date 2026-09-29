RSpec.describe DfeRb::Nfe::Formatter do
  let(:schema) { DfeRb::Nfe::Schema.nfe.find("infNFe") }
  let(:prod) { schema.find("det").find("prod") }
  let(:total) { schema.find("total").find("ICMSTot") }
  let(:ide) { schema.find("ide") }

  def written(value, element) = described_class.format(value, element)

  describe "money (TDec_1302)" do
    it "always uses two places, rounding half up" do
      expect(written(100, total.find("vProd"))).to eq("100.00")
      expect(written("10.5", total.find("vProd"))).to eq("10.50")
      expect(written(BigDecimal(0), total.find("vProd"))).to eq("0.00")
      expect(written(1234.567, total.find("vProd"))).to eq("1234.57")
      expect(written("2.005", total.find("vProd"))).to eq("2.01")
    end

    it "rejects negatives and non-numbers" do
      expect { written(-1, total.find("vProd")) }.to raise_error(described_class::Invalid, /negative/)
      expect { written("1,50", total.find("vProd")) }.to raise_error(described_class::Invalid, /expected a number/)
    end
  end

  describe "optional money (TDec_1302Opc)" do
    it "leaves zero out and keeps two places otherwise" do
      expect(written(0, prod.find("vFrete"))).to be_nil
      expect(written("0.10", prod.find("vFrete"))).to eq("0.10")
      expect(written(5, prod.find("vFrete"))).to eq("5.00")
    end
  end

  describe "quantities and unit prices" do
    it "use the fewest places the layout accepts" do
      expect(written(2, prod.find("qCom"))).to eq("2")
      expect(written(2.5, prod.find("qCom"))).to eq("2.5")
      expect(written("0.123456", prod.find("qCom"))).to eq("0.1235")
      expect(written(10, prod.find("vUnCom"))).to eq("10")
      expect(written("10.123456789012", prod.find("vUnCom"))).to eq("10.123456789")
    end
  end

  describe "percentages (TDec_0302a04)" do
    let(:rate) { schema.find("det").find("imposto").find("ICMS").find("ICMS00").find("pICMS") }

    it "use two to four places" do
      expect(written(18, rate)).to eq("18.00")
      expect(written("18.5", rate)).to eq("18.50")
      expect(written("12.3456", rate)).to eq("12.3456")
    end
  end

  describe "codes" do
    it "pads fixed-length digit codes that arrive as integers" do
      expect(written(7, ide.find("cUF"))).to eq("7")
      expect(written(12_345, schema.find("emit").find("enderEmit").find("CEP"))).to eq("00012345")
      expect(written(1234, ide.find("nNF"))).to eq("1234")
    end
  end

  describe "dates and times" do
    it "writes the emission time with a whole-hour offset" do
      expect(written(Time.new(2026, 9, 29, 10, 30, 0, "-03:00"), ide.find("dhEmi"))).to eq("2026-09-29T10:30:00-03:00")
      expect { written(Time.new(2026, 9, 29, 10, 30, 0, "+05:30"), ide.find("dhEmi")) }.to raise_error(described_class::Invalid, /whole-hour/)
    end

    it "writes dates as YYYY-MM-DD" do
      expect(written(Date.new(2026, 10, 5), schema.find("cobr").find("dup").find("dVenc"))).to eq("2026-10-05")
    end
  end

  describe "text" do
    let(:name) { prod.find("xProd") }

    it "cleans control characters and edges" do
      expect(written("  linha1\nlinha2\t ", name)).to eq("linha1 linha2")
    end

    it "keeps accented Latin-1 letters and rejects other characters" do
      expect(written("PRODUÇÃO AÇÚCAR", name)).to eq("PRODUÇÃO AÇÚCAR")
      expect { written("preço €", name) }.to raise_error(described_class::Invalid, /outside ISO-8859-1 \(€\)/)
    end

    it "enforces the length limits" do
      expect { written("", name) }.to raise_error(described_class::Invalid, /too short/)
      expect { written("x" * 121, name) }.to raise_error(described_class::Invalid, /too long \(121 characters, maximum 120\)/)
    end

    it "accepts binary-encoded strings (e.g. read from a certificate)" do
      expect(written("11444777000161".b, schema.find("emit").find("CNPJ"))).to eq("11444777000161")
    end
  end
end
