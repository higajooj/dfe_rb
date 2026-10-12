RSpec.describe DfeRb::Mdfe::Schema do
  let(:info) { described_class.mdfe.find("infMDFe") }

  it "reads the MDF-e layout with the four modals under infModal" do
    modal = info.find("infModal")

    expect(info.each_element.map(&:tag)).to start_with(%w[ide emit infModal infDoc])
    expect(modal.each_element.map(&:tag)).to eq(%w[rodo aereo aquav ferrov])
    expect(modal.attributes.map(&:name)).to eq(["versaoModal"])
    expect(modal.find("rodo").find("veicTracao").path).to eq("MDFe/infMDFe/infModal/rodo/veicTracao")
    expect(modal.find("rodo").find("veicReboque")).to have_attributes(min: 0, max: 3)
  end

  it "keeps the QR code and the signature beside infMDFe" do
    expect(described_class.mdfe.each_element.map(&:tag)).to eq(%w[infMDFe infMDFeSupl Signature])
  end

  describe DfeRb::Schema do
    it "reads a root declared as a global element, under a path of its own" do
      root = described_class.new(directory: DfeRb::Mdfe::Schema::DIRECTORY,
        files: %w[mdfeModalAereo_v3.00.xsd tiposGeralMDFe_v3.00.xsd], element: "aereo", path: "infModal").root

      expect(root).to have_attributes(tag: "aereo", path: "infModal/aereo")
      expect(root.each_element.map(&:tag)).to eq(%w[nac matr nVoo cAerEmb cAerDes dVoo])
    end
  end
end
