RSpec.describe DfeRb::Schema do
  let(:namespace) { "http://example.test/manifest" }
  let(:root) do
    described_class.new(directory: File.expand_path("../fixtures/layout", __dir__), files: %w[manifest_v1.00.xsd types_v1.00.xsd],
      type: "TManifest", tag: "Manifest").root
  end

  it "reads any document's layout from its XSD files and root type" do
    info = root.find("infManifest")

    expect(root).to have_attributes(tag: "Manifest", path: "Manifest")
    expect(info.each_element.map(&:tag)).to eq(%w[serie vCarga doc])
    expect(info.find("doc")).to have_attributes(min: 0, max: 3)
    expect(info.find("vCarga").type.name).to eq("TDec_1302")
    expect(info.attributes.map(&:name)).to eq(["Id"])
  end

  it "is what the writer follows, in the document's namespace" do
    writer = DfeRb::XmlWriter.new(root, namespace: namespace)
    xml = writer.write("infManifest" => {"@Id" => "M1", "doc" => %w[a b], "vCarga" => 1500, "serie" => 1})

    expect(xml).to eq(%(<Manifest xmlns="#{namespace}"><infManifest Id="M1"><serie>1</serie><vCarga>1500.00</vCarga><doc>a</doc><doc>b</doc></infManifest></Manifest>))
    expect(writer.issues).to eq([])
  end

  it "reports what doesn't belong to the layout under the document's own root" do
    writer = DfeRb::XmlWriter.new(root, namespace: namespace)
    writer.write("infManifest" => {"serie" => 1, "vCarga" => "x", "other" => 1})

    expect(writer.issues).to contain_exactly("Manifest/infManifest: unknown element other", a_string_starting_with("Manifest/infManifest/vCarga: "))
  end
end
