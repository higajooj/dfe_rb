RSpec.describe DfeRb::TaxId do
  describe ".normalize" do
    it "strips punctuation and upcases" do
      expect(described_class.normalize("12.abc.345/01de-35")).to eq("12ABC34501DE35")
    end
  end

  describe "CNPJ" do
    it "accepts numeric CNPJs with a correct check digit" do
      expect(described_class.cnpj?("11.222.333/0001-81")).to be(true)
      expect(described_class.cnpj?("11444777000161")).to be(true)
    end

    it "accepts alphanumeric CNPJs (RFB's published example)" do
      expect(described_class.cnpj?("12.ABC.345/01DE-35")).to be(true)
      expect(described_class.cnpj_check_digits("12ABC34501DE")).to eq("35")
    end

    it "rejects wrong check digits, wrong sizes and repeated characters" do
      expect(described_class.cnpj?("11222333000182")).to be(false)
      expect(described_class.cnpj?("1122233300018")).to be(false)
      expect(described_class.cnpj?("00000000000000")).to be(false)
      expect(described_class.cnpj?("12ABC34501DE3A")).to be(false)
    end
  end

  describe "CPF" do
    it "validates the check digits" do
      expect(described_class.cpf?("529.982.247-25")).to be(true)
      expect(described_class.cpf?("52998224726")).to be(false)
      expect(described_class.cpf?("11111111111")).to be(false)
    end
  end

  describe ".type" do
    it "tells CNPJ from CPF" do
      expect(described_class.type("11.222.333/0001-81")).to eq(:cnpj)
      expect(described_class.type("529.982.247-25")).to eq(:cpf)
      expect(described_class.type("123")).to be_nil
    end
  end
end
