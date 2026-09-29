require_relative "lib/dfe_rb/version"

Gem::Specification.new do |spec|
  spec.name = "dfe_rb"
  spec.version = DfeRb::VERSION
  spec.authors = ["Daniel Higa"]
  spec.email = ["danielhiga10@gmail.com"]

  spec.summary = "Brazilian SEFAZ DF-e client: emit NF-e, query distribution, manifest as recipient."
  spec.description = "Issues NF-e (modelo 55, layout 4.00) in production and homologacao with an A1 certificate: " \
    "builds and validates the XML, signs it, authorizes it (sync and lot), consults, cancels, corrects and " \
    "inutilizes. Also queries NFeDistribuicaoDFe with typed document metadata and sends all four recipient manifestation events."
  spec.homepage = "https://github.com/higajooj/dfe_rb"
  spec.license = "MPL-2.0"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*", "LICENSE.txt", "README.md", "CHANGELOG.md"].select { |f| File.file?(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "base64"
  spec.add_dependency "bigdecimal"
  spec.add_dependency "nokogiri", "~> 1.16"

  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "standard", "~> 1.50"
  spec.add_development_dependency "webmock", "~> 3.23"
end
