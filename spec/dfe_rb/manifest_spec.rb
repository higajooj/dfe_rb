require "yaml"

# lib/dfe_rb/data/manifest.yml lists every official document the gem follows (CONTRIBUTING.md).
RSpec.describe "the compliance manifest" do
  root = File.expand_path("../..", __dir__)
  manifest = YAML.safe_load_file(File.join(root, "lib/dfe_rb/data/manifest.yml"), permitted_classes: [Date])
  documents = manifest.fetch("documents")
  kinds = %w[moc nt it schema table law guide certificate]
  statuses = %w[implemented pending out_of_scope]
  areas = %w[nfe nfce mdfe events distribution ibs_cbs efd]

  it "describes each document with the same fields" do
    documents.each do |row|
      expect(row.keys).to include("id", "document", "kind", "status", "dfe", "version", "published", "production",
        "implemented_in", "source", "sha256"), row["id"].inspect
      expect(kinds).to include(row["kind"]), row["id"]
      expect(statuses).to include(row["status"]), row["id"]
      expect(areas).to include(*row["dfe"]), row["id"]
      expect(row["sha256"]).to(match(/\A\h{64}\z/), row["id"]) unless row["sha256"].nil?
    end
    expect(documents.map { |row| row["id"] }).to eq(documents.map { |row| row["id"] }.uniq)
  end

  it "names files that exist" do
    paths = documents.flat_map { |row| Array(row["implemented_in"]) + Array(row["tables"]) + Array(row["schemas"]) }

    expect(paths.reject { |path| File.exist?(File.join(root, path)) }).to eq([])
  end

  it "has a row for every table the gem ships" do
    tables = Dir.glob("lib/**/*.{tsv,pem}", base: root).sort
    listed = documents.flat_map { |row| Array(row["tables"]) }

    expect(tables - listed).to eq([])
  end

  it "has a row for every schema package the gem ships" do
    packages = Dir.glob("lib/dfe_rb/xml/schemas/*/", base: root).map { |path| path.delete_suffix("/") }.sort
    listed = documents.flat_map { |row| Array(row["schemas"]) }

    expect(packages - listed).to eq([])
  end

  it "covers the NF-e, the NFC-e, the MDF-e, events, distribution and the IBS/CBS tables" do
    implemented = documents.select { |row| row["status"] == "implemented" }.flat_map { |row| row["dfe"] }

    expect(implemented.uniq).to include("nfe", "nfce", "mdfe", "events", "distribution", "ibs_cbs")
  end

  it "keeps what a row not followed leaves out, and what the gem is waiting for, in words" do
    documents.reject { |row| row["status"] == "implemented" }.each { |row| expect(row["note"].to_s).not_to be_empty, row["id"] }
    manifest.fetch("awaiting").each { |item| expect(item.keys).to include("what", "affects", "source") }
  end
end
