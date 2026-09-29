RSpec.describe DfeRb::Nfe::AccessKey do
  # The worked example in MOC 7.0 §2.2.6.2: weighted sum 644, so the check digit is 5.
  let(:moc_first43) { "5206043300991100250655012000000780026730161" }

  describe ".check_digit" do
    it "computes the modulo 11 digit as the MOC does" do
      expect(described_class.check_digit(moc_first43)).to eq("5")
    end

    it "returns 0 when the remainder is 0 or 1" do
      expect(described_class.check_digit("0" * 43)).to eq("0")
    end

    it "counts alphanumeric CNPJ characters as ASCII code minus 48" do
      # Weighted sum 841 (A=17, B=18, C=19, D=20, E=21), remainder 5, so the digit is 6.
      body = "35" + "2609" + "12ABC34501DE35" + "55" + "001" + "000000001" + "1" + "12345670"

      expect(described_class.check_digit(body)).to eq("6")
      expect(described_class.valid?(body + "6")).to be(true)
    end
  end

  describe ".valid?" do
    it "accepts the MOC example and rejects a wrong digit or size" do
      expect(described_class.valid?(moc_first43 + "5")).to be(true)
      expect(described_class.valid?(moc_first43 + "4")).to be(false)
      expect(described_class.valid?("123")).to be(false)
    end
  end

  describe ".build" do
    let(:key) do
      described_class.build(state: "SP", issued_at: Time.new(2026, 9, 29), tax_id: "11.444.777/0001-61",
        series: 1, number: 1234, numeric_code: "00098765")
    end

    it "assembles cUF AAMM CNPJ mod serie nNF tpEmis cNF cDV" do
      expect(key.to_s).to match(/\A3526091144477700016155001000001234100098765\d\z/)
      expect(key.state_code).to eq("35")
      expect(key.year_month).to eq("2609")
      expect(key.tax_id).to eq("11444777000161")
      expect(key.model).to eq(55)
      expect(key.series).to eq(1)
      expect(key.number).to eq(1234)
      expect(key.emission_type).to eq(1)
      expect(key.numeric_code).to eq("00098765")
      expect(key.id).to eq("NFe#{key}")
      expect(described_class.valid?(key.to_s)).to be(true)
    end

    it "left-pads a CPF to 14 positions" do
      cpf_key = described_class.build(state: "SP", issued_at: Time.new(2026, 9, 1), tax_id: "529.982.247-25",
        series: 920, number: 1, numeric_code: "12345670")
      expect(cpf_key.tax_id).to eq("00052998224725")
    end

    it "accepts alphanumeric CNPJs" do
      alnum = described_class.build(state: "SP", issued_at: Time.new(2026, 9, 1), tax_id: "12.ABC.345/01DE-35",
        series: 1, number: 1, numeric_code: "12345670")
      expect(alnum.tax_id).to eq("12ABC34501DE35")
      expect(described_class.valid?(alnum.to_s)).to be(true)
    end
  end

  describe ".parse" do
    it "rejects invalid keys" do
      expect { described_class.parse("nope") }.to raise_error(ArgumentError, /invalid access key/)
    end
  end

  describe ".generate_numeric_code" do
    it "never returns a forbidden pattern or the invoice number" do
      random = instance_double(Random)
      allow(random).to receive(:random_number).and_return(11_111_111, 12_345_678, 1234, 55_667_788)

      expect(described_class.generate_numeric_code(number: 1234, random: random)).to eq("55667788")
    end

    it "returns 8 digits" do
      expect(described_class.generate_numeric_code(number: 1)).to match(/\A[0-9]{8}\z/)
    end
  end
end
