RSpec.describe DfeRb::Mdfe::Manifest do
  let(:clock) { class_double(Time, now: Time.new(2026, 10, 12, 15, 0, 0, "+00:00")) }
  let(:manifest) { own_cargo_manifest(clock: clock) }
  let(:tree) { manifest.resolved }

  it "builds an <MDFe> that satisfies the layout and the road modal's own schema" do
    xml = manifest.to_xml

    expect(xml).to start_with(%(<MDFe xmlns="http://www.portalfiscal.inf.br/mdfe"><infMDFe Id="MDFe#{manifest.key}" versao="3.00">))
    expect(DfeRb::Mdfe::Schemas.mdfe_issues(xml)).to eq([])
    expect(manifest.issues).to eq([])
  end

  it "fills in what follows from the rest" do
    expect(tree["ide"]).to include("cUF" => "35", "tpAmb" => "2", "mod" => 58, "modal" => 1, "tpEmis" => 1, "procEmi" => 0,
      "UFIni" => "SP", "UFFim" => "RJ", "tpEmit" => 2)
    expect(tree["ide"]["dhEmi"].strftime("%Y-%m-%dT%H:%M:%S%:z")).to eq("2026-10-12T12:00:00-03:00")
    expect(tree["infModal"]["@versaoModal"]).to eq("3.00")
    expect(tree["tot"]).to include("qNFe" => 2, "cUnid" => "01")
    expect(tree["tot"]).not_to include("qCTe", "qMDFe")
    expect(tree["emit"]["enderEmit"]).to include("xMun" => "São Paulo", "UF" => "SP")
  end

  it "names cities from the IBGE table, given by name and state or by code" do
    expect(tree["ide"]["infMunCarrega"]).to eq([{"cMunCarrega" => "3550308", "xMunCarrega" => "São Paulo"}])
    expect(tree["infDoc"]["infMunDescarga"].first).to include("cMunDescarga" => "3304557", "xMunDescarga" => "Rio de Janeiro")
    expect { own_cargo_manifest { |mdfe| mdfe.load_at "Sao Paolo", "SP" } }
      .to raise_error(ArgumentError, 'no city called "Sao Paolo" in SP (give its IBGE code)')
  end

  it "gathers the documents of a city named more than once" do
    again = own_cargo_manifest { |mdfe| mdfe.unload_at("3304557") { |city| city.nfe document_key(55, number: 7) } }

    cities = again.resolved["infDoc"]["infMunDescarga"]
    expect(cities.size).to eq(1)
    expect(cities.first["infNFe"].size).to eq(3)
    expect(again.resolved["tot"]["qNFe"]).to eq(3)
  end

  it "builds the access key of modelo 58 and keeps it across calls" do
    key = manifest.key

    expect(key).to have_attributes(model: 58, series: 1, number: 10, state: "SP", tax_id: MdfeHelpers::ISSUER, emission_type: 1)
    expect(manifest.key).to eq(key)
    expect(manifest.to_xml).to include(%(Id="MDFe#{key}"))
  end

  it "takes codes as people type them" do
    typed = own_cargo_manifest do |mdfe|
      mdfe.issuer tax_id: "11.444.777/0001-61", address: {zip: "01001-000"}
      mdfe.road { |road| road.trailer plate: "xyz-1234", tare: 7000, capacity_kg: 30_000, body: :open }
    end

    expect(typed.issues).to eq([])
    expect(typed.to_xml).to include("<CNPJ>11444777000161</CNPJ>", "<CEP>01001000</CEP>", "<placa>XYZ1234</placa>")
  end

  it "points the QR code at the Portal Nacional, without a signature" do
    expect(manifest.qr_code).to eq("https://dfe-portal.svrs.rs.gov.br/mdfe/qrCode?chMDFe=#{manifest.key}&tpAmb=2")
    expect(manifest.to_xml).to include("<infMDFeSupl><qrCodMDFe>https://dfe-portal.svrs.rs.gov.br/mdfe/qrCode?chMDFe=#{manifest.key}&amp;tpAmb=2</qrCodMDFe></infMDFeSupl>")
  end

  it "suggests the field meant by a misspelled one" do
    expect { own_cargo_manifest { |mdfe| mdfe.road { |road| road.vehicle plat: "ABC1D23" } } }
      .to raise_error(NoMethodError, /veicTracao has no field "plat" \(did you mean "plate"/)
  end

  it "reports every problem at once" do
    broken = own_cargo_manifest { |mdfe| mdfe.cargo value: "abc" }

    expect { broken.to_xml }.to raise_error(DfeRb::ValidationError) { |error|
      expect(error.issues).to include(a_string_starting_with("MDFe/infMDFe/tot/vCarga: "))
    }
  end

  describe "a carrier's manifest" do
    let(:manifest) { carrier_manifest(clock: clock) }

    it "is valid with its ANTT groups, insurance and full load" do
      expect(manifest.issues).to eq([])
    end

    it "takes the kind of carrier and the contractor from the vehicle's owner" do
      expect(tree["ide"]).to include("tpTransp" => 2, "UFIni" => "SP", "UFFim" => "GO")
      expect(tree["ide"]["infPercurso"]).to eq([{"UFPer" => "MG"}])
      expect(tree.dig("infModal", "rodo", "infANTT", "infContratante")).to eq([{"CNPJ" => MdfeHelpers::ISSUER}])
      expect(tree["tot"]).to include("qCTe" => 1, "cUnid" => "02")
    end

    it "numbers the freight's installments" do
      paid_later = carrier_manifest(clock: clock) do |mdfe|
        mdfe.road do |road|
          road.freight_payment tax_id: "11222333000181", total: "500.00", terms: :installments, advance: "100.00" do |payment|
            payment.component :freight, "500.00"
            payment.installment Date.new(2026, 11, 10), "200.00"
            payment.installment Date.new(2026, 12, 10), "200.00"
            payment.bank bank_code: "001", branch: "1234"
          end
        end
      end

      expect(paid_later.issues).to eq([])
      expect(paid_later.to_xml).to include("<infPrazo><nParcela>001</nParcela><dVenc>2026-11-10</dVenc><vParcela>200.00</vParcela></infPrazo>",
        "<nParcela>002</nParcela>", "<infBanc><codBanco>001</codBanco><codAgencia>1234</codAgencia></infBanc>")
    end
  end

  describe "the other modals, filled by tag" do
    def manifest_by(&modal)
      described_class.new(number: 3, issuer_type: :own_cargo) do |mdfe|
        mdfe.issuer tax_id: MdfeHelpers::ISSUER, name: "X LTDA", state_registration: "111111111111", address: issuer_address
        mdfe.load_at "Sao Paulo", "SP"
        mdfe.unload_at "Santos", "SP", nfe: [document_key(55)]
        mdfe.cargo value: 1, weight: 1
        modal.call(mdfe)
      end
    end

    it "writes an air manifest" do
      manifest = manifest_by do |mdfe|
        mdfe.air nac: "PRAB", matr: "PRABCD", n_voo: "AB1234", c_aer_emb: "GRU", c_aer_des: "SDU", d_voo: Date.new(2026, 10, 12)
      end

      expect(manifest.issues).to eq([])
      expect(manifest.resolved["ide"]["modal"]).to eq(2)
      expect(manifest.to_xml).to include(%(<infModal versaoModal="3.00"><aereo><nac>PRAB</nac>), "<dVoo>2026-10-12</dVoo>")
    end

    it "writes a water manifest" do
      manifest = manifest_by do |mdfe|
        mdfe.water irin: "1234567", tp_emb: "01", c_embar: "123", x_embar: "BARCO", n_viag: "1", c_prt_emb: "BRSSZ", c_prt_dest: "BRRIO"
      end

      expect(manifest.issues).to eq([])
      expect(manifest.resolved["ide"]["modal"]).to eq(3)
    end

    it "writes a rail manifest" do
      manifest = manifest_by do |mdfe|
        mdfe.rail do |rail|
          rail.trem x_pref: "TR1", x_ori: "ABC", x_dest: "DEF", q_vag: 1
          rail.vag peso_bc: "1.000", peso_r: "1.000", serie: "ABC", n_vag: 1, tu: "1.000"
        end
      end

      expect(manifest.issues).to eq([])
      expect(manifest.resolved["ide"]["modal"]).to eq(4)
    end

    it "reports what the modal's own schema refuses" do
      manifest = manifest_by { |mdfe| mdfe.air nac: "PRAB" }

      expect(manifest.issues).to include(a_string_including("Element 'nac': This element is not expected").or(a_string_including("Missing child element")))
    end
  end

  describe "in contingency" do
    let(:certificate) { mdfe_certificate }

    it "signs the key in the QR code with the certificate" do
      manifest = own_cargo_manifest(certificate: certificate, clock: clock, &:contingency)
      sign = manifest.qr_code[/&sign=(.*)\z/, 1]

      expect(manifest.key.emission_type).to eq(2)
      expect(manifest.issues).to eq([])
      expect(certificate.certificate.public_key.verify(OpenSSL::Digest.new("SHA1"), Base64.strict_decode64(sign), manifest.key.to_s)).to be(true)
    end

    it "says the certificate is missing" do
      manifest = own_cargo_manifest(clock: clock, &:contingency)

      expect(manifest.qr_code).to be_nil
      expect(manifest.issues).to include(a_string_starting_with("a manifest issued in contingency needs the certificate"))
    end
  end

  it "computes the hashCSRT of a technical contact" do
    contact = {cnpj: "11222333000181", contact: "Dev", email: "dev@example.com", phone: "1133334444", csrt_id: "001", csrt: "G8063VRTNDMO886SFNK5LDUDEI24XJ22YIPO"}
    manifest = own_cargo_manifest(technical_contact: contact, clock: clock)

    expected = Base64.strict_encode64(Digest::SHA1.digest("#{contact[:csrt]}#{manifest.key}"))
    expect(manifest.issues).to eq([])
    expect(manifest.to_xml).to include("<idCSRT>001</idCSRT><hashCSRT>#{expected}</hashCSRT>")
    expect(manifest.to_xml).not_to include(contact[:csrt])
  end
end
