require "cgi"
require "uri"

# The signature of an off-line QR code (tpEmis 9) in the URL: NT 2026.003 §4.3.2, Tabela 2,
# 8th parameter, and its model URL, which prints standard Base64 with `+`, `/` and `=` raw.
RSpec.describe DfeRb::Nfce::QrCode do
  let(:certificate) { nfe_certificate }
  let(:key) { "50261111444777000161650010000000119000000100" }
  let(:address) { "http://www.dfe.ms.gov.br/nfce/qrcode" }

  # RSA-SHA1 is deterministic, so a day or a total is tried until the signature holds the
  # three characters a URL encoder would touch.
  def offline_url_with_all_base64_marks
    (1..400).each do |cents|
      url = described_class.offline(address: address, key: key, environment: :homologacao, issued_at: Time.new(2026, 11, 5, 14, 30, 0, "-04:00"),
        total: format("%.2f", cents / 100.0 + 8), recipient: {"CPF" => "52998224725"}, certificate: certificate)
      signature = url.split("|").last
      return url if %w[+ / =].all? { |mark| signature.include?(mark) }
    end
    raise "no signature with +, / and = in 400 tries"
  end

  describe ".offline" do
    it "writes the signature as standard Base64 after the seventh parameter, its +, / and = raw (NT 2026.003 §4.3.2)" do
      url = offline_url_with_all_base64_marks
      signature = url.split("|").last

      expect(signature).to match(%r{\A[A-Za-z0-9+/]+={0,2}\z}).and include("+", "/", "=")
      expect(url).not_to match(/%2B|%2F|%3D/i)
      expect(url).to start_with("#{address}?p=#{key}|3|2|05|")
      expect(url.count("|")).to eq(7)
    end

    it "round-trips through parse and signed_by? with a signature that holds +, / and =" do
      parsed = described_class.parse(offline_url_with_all_base64_marks)

      expect(parsed[:signature]).to include("+", "/", "=")
      expect(described_class.signed_by?(parsed[:signed_content], parsed[:signature], certificate.certificate)).to be(true)
    end

    it "puts such a signature in the XML's qrCode as it is, with nothing to escape" do
      url = offline_url_with_all_base64_marks

      expect(CGI.escapeHTML(url)).to eq(url)
    end
  end

  describe "a signature that went through a URL encoder" do
    let(:url) { offline_url_with_all_base64_marks }
    let(:raw) { described_class.parse(url) }

    def verified?(altered)
      parsed = described_class.parse(altered)
      described_class.signed_by?(parsed[:signed_content], parsed[:signature], certificate.certificate)
    end

    it "is read when percent-encoded" do
      encoded = url.sub(/[^|]+\z/) { |signature| URI.encode_www_form_component(signature) }

      expect(encoded).to match(/%2B|%2F|%3D/i)
      expect(described_class.parse(encoded)[:signature]).to eq(raw[:signature])
      expect(verified?(encoded)).to be(true)
    end

    it "is read when a form decoder turned its + into spaces" do
      spaced = url.sub(/[^|]+\z/) { |signature| signature.tr("+", " ") }

      expect(verified?(spaced)).to be(true)
    end

    it "is read in the URL-safe alphabet, with or without padding" do
      safe = url.sub(/[^|]+\z/) { |signature| signature.tr("+/", "-_") }

      expect(verified?(safe)).to be(true)
      expect(verified?(safe.delete_suffix("=="))).to be(true)
    end

    it "still refuses a signature of other content" do
      parsed = described_class.parse(url)

      expect(described_class.signed_by?("#{parsed[:signed_content]}x", parsed[:signature], certificate.certificate)).to be(false)
      expect(described_class.signed_by?(parsed[:signed_content], "%%%", certificate.certificate)).to be(false)
    end
  end
end
