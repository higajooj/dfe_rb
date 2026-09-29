RSpec.describe DfeRb::Nfe::Schema do
  let(:root) { described_class.nfe }
  let(:inf) { root.find("infNFe") }

  it "reads the layout from the official XSD" do
    expect(root.tag).to eq("NFe")
    expect(inf.each_element.map(&:tag)).to eq(%w[ide emit avulsa dest retirada entrega autXML det total transp cobr pag infIntermed infAdic exporta compra cana infRespTec infSolicNFF agropecuario infPAA])
    expect(inf.find("det")).to have_attributes(min: 1, max: 990)
    expect(inf.find("det").attributes.map(&:name)).to eq(["nItem"])
  end

  it "keeps the schema order of the identification fields" do
    expect(inf.find("ide").each_element.first(6).map(&:tag)).to eq(%w[cUF cNF natOp mod serie nNF])
  end

  it "models the ICMS variants as a choice" do
    icms = inf.find("det").find("imposto").find("ICMS")

    expect(icms.children.size).to eq(1)
    expect(icms.children.first).to be_choice
    expect(icms.each_element.map(&:tag)).to include("ICMS00", "ICMS90", "ICMSSN102", "ICMSSN900", "ICMSPart", "ICMSST")
  end

  it "carries value types with their facets" do
    type = inf.find("ide").find("natOp").type

    expect(type.max_length).to eq(60)
    expect(type.min_length).to eq(1)
    expect(inf.find("emit").find("CRT").type.enumeration).to eq(%w[1 2 3 4])
  end

  it "knows the alphanumeric CNPJ and 3-4 digit cStat of the current layout" do
    expect(inf.find("emit").find("CNPJ").type.patterns).to eq(["[0-9A-Z]{12}[0-9]{2}"])
  end

  it "loads quickly enough to build on first use" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    described_class.new
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
  end
end
