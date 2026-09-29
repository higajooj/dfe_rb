require_relative "lib/dfe_rb/version"

Gem::Specification.new do |spec|
  spec.name = "dfe_rb"
  spec.version = DfeRb::VERSION
  spec.authors = ["Daniel Higa"]
  spec.email = ["danielhiga10@gmail.com"]

  spec.summary = "Brazilian SEFAZ DF-e client: NF-e distribution queries and recipient manifestation."
  spec.description = "Talks to the SEFAZ NFeDistribuicaoDFe and NFeRecepcaoEvento web services with an A1 " \
    "certificate: fetches documents by NSU or access key and sends signed manifestation events."
  spec.homepage = "https://github.com/higajooj/dfe_rb"
  spec.license = "MPL-2.0"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*", "LICENSE.txt", "README.md", "CHANGELOG.md"].select { |f| File.file?(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "base64"
  spec.add_dependency "nokogiri", "~> 1.16"
  spec.add_dependency "savon", "~> 2.17"

  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "standard", "~> 1.50"
  spec.add_development_dependency "webmock", "~> 3.23"
end
