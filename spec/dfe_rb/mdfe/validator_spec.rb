RSpec.describe DfeRb::Mdfe::Validator do
  let(:clock) { class_double(Time, now: Time.new(2026, 10, 12, 15, 0, 0, "+00:00")) }

  def issues_of(manifest) = manifest.issues

  def own_cargo(&block) = own_cargo_manifest(clock: clock, &block)

  def carrier(&block) = carrier_manifest(clock: clock, &block)

  it "has nothing to say about a correct manifest" do
    expect(issues_of(own_cargo)).to eq([])
    expect(issues_of(carrier)).to eq([])
  end

  describe "the issuer" do
    it "checks its CNPJ, state registration and series" do
      found = issues_of(own_cargo { |mdfe|
        mdfe.issuer cnpj: "11444777000162", state_registration: "0"
        mdfe.series 920
      })

      expect(found).to include(
        "emit/CNPJ: 11444777000162 is not a valid CNPJ (F67, rej. 207)",
        "emit/IE: the issuer's state registration is required (F72, rej. 229)",
        "ide/serie: series 920 to 969 are kept for issuers with a CPF (F69, rej. 232)"
      )
    end

    it "lets a person issue only for own cargo, in the series kept for them" do
      found = issues_of(carrier { |mdfe| mdfe.issuer tax_id: "12345678909" })

      expect(found).to include(
        "ide/serie: an issuer with a CPF uses series 920 to 969 (F70, rej. 233)",
        "ide/tpEmit: an issuer with a CPF can only carry its own cargo, tpEmit 2 (F71, rej. 234)"
      )
    end

    it "checks that its city belongs to its state" do
      found = issues_of(own_cargo { |mdfe| mdfe.issuer address: {state: "RJ"} })

      expect(found).to include("emit/enderEmit/cMun: city 3550308 does not belong to RJ (F77, rej. 613)")
    end
  end

  describe "the emission time" do
    it "refuses the future, and a normal emission more than a day old" do
      late = own_cargo { |mdfe| mdfe.issued_at Time.new(2026, 10, 10, 9, 0, 0, "-03:00") }
      early = own_cargo { |mdfe| mdfe.issued_at Time.new(2026, 10, 12, 13, 0, 0, "-03:00") }

      expect(issues_of(late)).to include(a_string_including("(F80, rej. 228)"))
      expect(issues_of(early)).to include(a_string_including("(F79, rej. 212)"))
    end

    it "gives a manifest in contingency its 168 hours" do
      late = own_cargo_manifest(clock: clock, certificate: mdfe_certificate) do |mdfe|
        mdfe.contingency
        mdfe.issued_at Time.new(2026, 10, 10, 9, 0, 0, "-03:00")
      end

      expect(issues_of(late)).to eq([])
    end
  end

  describe "cities" do
    it "flags a city outside the trip's first or last state, unknown or repeated" do
      found = issues_of(own_cargo { |mdfe|
        mdfe.load_at "3550308"
        mdfe.load_at city_code: "3599999", city: "Lugar Nenhum"
        mdfe.end_state "SP"
      })

      expect(found).to include(
        "ide/infMunCarrega/cMunCarrega: city 3550308 is listed 2 times (F10, rej. 685)",
        "ide/infMunCarrega/cMunCarrega: 3599999 is not in the IBGE table of cities (F09, rej. 405)",
        "infDoc/infMunDescarga/cMunDescarga: city 3304557 does not belong to ide/UFFim SP (F11, rej. 612)"
      )
    end
  end

  describe "documents" do
    it "wants at least one per unloading city" do
      found = issues_of(own_cargo { |mdfe| mdfe.unload_at "Niteroi", "RJ" })

      expect(found).to include("infDoc/infMunDescarga 3303302: no document unloads here; list its CT-e, NF-e or MDF-e (F26, rej. 616)")
    end

    it "matches the kind of document to the kind of issuer" do
      expect(issues_of(own_cargo { |mdfe| mdfe.unload_at "3304557", cte: [document_key(57)] }))
        .to include("infDoc: an own-cargo issuer (tpEmit 2) lists NF-e, not CT-e (F15, rej. 639)")
      expect(issues_of(carrier { |mdfe| mdfe.unload_at "5208707", nfe: [document_key(55)] }))
        .to include("infDoc: a carrier (tpEmit 1) lists CT-e, not NF-e (F14, rej. 638)")
    end

    it "checks each key: digits, model and repetition" do
      wrong_model = document_key(57)
      found = issues_of(own_cargo { |mdfe|
        mdfe.unload_at "3304557", nfe: [document_key(55), wrong_model, "3" * 44]
      })

      expect(found).to include(
        a_string_including("#{document_key(55)} is listed 2 times (rej. 669)"),
        a_string_including("#{wrong_model} is of model 57, not 55 (rej. 604)"),
        a_string_including("#{"3" * 44} is not a valid access key")
      )
    end

    it "checks what the key is made of, and that it isn't older than six months" do
      parts = {state: "SP", tax_id: "11222333000181", series: 1, numeric_code: "12345679", model: 55}
      old = DfeRb::AccessKey.build(issued_at: Time.new(2025, 1, 15), number: 7, **parts).to_s
      kept = DfeRb::AccessKey.build(issued_at: Time.new(2026, 4, 15), number: 8, **parts).to_s
      unnumbered = DfeRb::AccessKey.build(issued_at: clock.now, number: 0, **parts).to_s
      nobody = DfeRb::AccessKey.build(issued_at: clock.now, number: 9, **parts, tax_id: "11222333000182").to_s
      found = issues_of(own_cargo { |mdfe| mdfe.unload_at "3304557", nfe: [old, kept, unnumbered, nobody] })

      expect(found).to include(
        a_string_including("#{old} is from 01/2025, more than 6 months ago (NT 2024.001, rej. 519)"),
        a_string_including("#{unnumbered} has document number zero (rej. 604)"),
        a_string_including("#{nobody} has an invalid issuer, 11222333000182 (rej. 604)")
      )
      expect(found.grep(/#{kept}/)).to eq([])
    end

    it "asks for the second bar code of a document issued on FS-DA paper, and of no other" do
      paper = document_key(55, number: 9, emission_type: 5)
      found = issues_of(own_cargo { |mdfe|
        mdfe.unload_at("3304557") do |city|
          city.nfe paper
          city.nfe document_key(55, number: 8), barcode: "1" * 36
        end
      })

      expect(found).to include(a_string_including("#{paper} was issued on FS-DA paper; its second bar code (SegCodBarra) is required (rej. 606)"),
        a_string_including("it takes no second bar code (rej. 607)"))
    end

    it "compares the totals with what is listed" do
      expect(issues_of(own_cargo { |mdfe| mdfe.nfe_count 5 }))
        .to include("tot/qNFe: 5 differs from the 2 listed in infDoc (F51, rej. 667)")
    end

    it "lets only a water manifest of the north list other MDF-e" do
      found = issues_of(own_cargo { |mdfe| mdfe.unload_at "3304557", mdfe: [document_key(58)] })

      expect(found).to include("infDoc: only a water manifest can list other MDF-e (F43, rej. 647)",
        "infDoc: other MDF-e can be listed only when the trip starts or ends in AM or AP (F44, rej. 648)")
    end
  end

  describe "a manifest loaded later" do
    def later(&block)
      DfeRb::Mdfe::Manifest.new(clock: clock, number: 1, issuer_type: :own_cargo, later_loading: true) do |mdfe|
        mdfe.issuer tax_id: MdfeHelpers::ISSUER, name: "X LTDA", state_registration: "111111111111", address: issuer_address
        mdfe.load_at "3550308"
        mdfe.unload_at "3550308"
        mdfe.road { |road| road.vehicle(plate: "ABC1D23", tare: 9000, wheels: :truck, body: :closed) { |v| v.driver "Fulano", "12345678909" } }
        mdfe.cargo value: 1, weight: 1
        block&.call(mdfe)
      end
    end

    it "is valid with one city and no documents" do
      expect(issues_of(later)).to eq([])
      expect(later.to_xml).to include("<indCarregaPosterior>1</indCarregaPosterior>")
    end

    it "lists no documents and stays in one city" do
      found = issues_of(later { |mdfe|
        mdfe.unload_at "3550308", nfe: [document_key(55)]
        mdfe.unload_at "3509502"
      })

      expect(found).to include(a_string_including("(F21, rej. 703)"), a_string_including("(F27, rej. 706)"))
    end

    it "drops an indicator set to false" do
      expect(own_cargo { |mdfe| mdfe.later_loading false }.to_xml).not_to include("indCarregaPosterior")
    end
  end

  describe "the road modal" do
    it "checks drivers" do
      found = issues_of(own_cargo { |mdfe|
        mdfe.road { |road| road.vehicle { |vehicle| vehicle.drivers [{name: "Fulano", cpf: "12345678909"}, {name: "Beltrano", cpf: "11111111111"}] } }
      })

      expect(found).to include("infModal/rodo/veicTracao/condutor/CPF: 12345678909 is listed 2 times (F99, rej. 577)",
        "infModal/rodo/veicTracao/condutor/CPF: 11111111111 is not a valid CPF (F100, rej. 645)")
    end

    it "ties the kind of carrier to the traction vehicle's owner" do
      without_owner = own_cargo { |mdfe| mdfe.carrier_type :etc }
      company_owner = carrier { |mdfe|
        mdfe.carrier_type :tac
        mdfe.road { |road| road.vehicle { |vehicle| vehicle.owner tax_id: "11222333000181" } }
      }

      expect(issues_of(without_owner)).to include("ide/tpTransp: not given unless the traction vehicle has an owner (F20, rej. 745)")
      expect(issues_of(company_owner)).to include("ide/tpTransp: must be ETC (1) or CTC (3) when the traction vehicle's owner has a CNPJ (F19, rej. 744)")
    end

    it "refuses the issuer as the owner, and any contractor but the issuer when there is an owner" do
      own = carrier { |mdfe| mdfe.road { |road| road.vehicle { |vehicle| vehicle.owner tax_id: MdfeHelpers::ISSUER } } }
      other = carrier { |mdfe| mdfe.road { |road| road.contractor cnpj: "11222333000181" } }

      expect(issues_of(own)).to include(a_string_including("(F64, rej. 740)"))
      expect(issues_of(other)).to include(a_string_including("(F65, rej. 741)"))
    end

    it "wants every state crossed, in order" do
      expect(issues_of(carrier)).not_to include(a_string_including("F90"))
      expect(issues_of(carrier { |mdfe| mdfe.route "TO" }))
        .to include("ide/infPercurso: MG and TO share no border; list every state crossed from SP to GO, in order, with `route` (F90, rej. 663)")
      expect(issues_of(own_cargo { |mdfe| mdfe.end_state "RS" }))
        .to include(a_string_starting_with("ide/infPercurso: SP and RS share no border"))
    end

    it "knows every border from both sides" do
      described_class::BORDERS.each do |state, neighbours|
        neighbours.each { |neighbour| expect(described_class::BORDERS.fetch(neighbour)).to include(state), "#{neighbour} lacks #{state}" }
      end
      expect(described_class::BORDERS.keys.sort).to eq(DfeRb::States::CODES.keys.sort)
    end

    it "checks a toll voucher" do
      found = issues_of(carrier { |mdfe| mdfe.road { |road| road.toll_voucher supplier: "11222333000182", payer: "12345678900", amount: "10.00" } })

      expect(found).to include(
        "infModal/rodo/infANTT/valePed/categCombVeic: the vehicle category is required with a toll voucher (F95, rej. 731)",
        "infModal/rodo/infANTT/valePed/disp/CNPJForn: 11222333000182 is not a valid CNPJ (F96, rej. 732)",
        "infModal/rodo/infANTT/valePed/disp/CPFPg: 12345678900 is not a valid CPF (F98, rej. 734)"
      )
    end
  end

  describe "transport for hire" do
    it "requires the cargo's insurance, complete" do
      partial = DfeRb::Mdfe::Validator.new(carrier.resolved.merge("seg" => [{"infResp" => {"respSeg" => "2"}}]), clock: clock).issues

      expect(partial).to include("seg[1]: the insurance lacks infSeg/xSeg, infSeg/CNPJ, nApol, nAver (F92, rej. 699)",
        "seg[1]/infResp: give the CNPJ or CPF of the contractor responsible for the insurance (F93, rej. 542)")
      expect(DfeRb::Mdfe::Validator.new(carrier.resolved.except("seg"), clock: clock).issues)
        .to include("seg: a carrier's road manifest declares the cargo's insurance (F91, rej. 698)")
    end

    it "requires the full load's place, NCM and payment when there is one document" do
      tree = carrier.resolved
      tree["prodPred"] = {"tpCarga" => "01", "xProd" => "Soja"}
      tree["infModal"]["rodo"]["infANTT"].delete("infPag")

      expect(DfeRb::Mdfe::Validator.new(tree, clock: clock).issues).to include(
        a_string_including("(F55, rej. 726)"), a_string_including("(F55a, rej. 301)"), a_string_including("(F55b, rej. 302)")
      )
    end

    it "requires the CIOT from the day NT 2026.001 sets for each environment" do
      tree = carrier.resolved
      tree["infModal"]["rodo"]["infANTT"].delete("infCIOT")
      production = Marshal.load(Marshal.dump(tree)).tap { |copy| copy["ide"]["tpAmb"] = "1" }

      expect(DfeRb::Mdfe::Validator.new(tree, clock: clock).issues)
        .to include("infModal/rodo/infANTT/infCIOT: the CIOT is required for transport for hire (NT 2026.001, rej. 684)")
      expect(DfeRb::Mdfe::Validator.new(production, clock: clock).issues).not_to include(a_string_including("rej. 684"))
    end

    it "adds up the freight's components and installments" do
      found = issues_of(carrier { |mdfe|
        mdfe.road do |road|
          road.freight_payment tax_id: "11222333000181", total: "500.00", terms: :installments do |payment|
            payment.component :freight, "400.00"
            payment.installment Date.new(2026, 10, 1), "100.00"
            payment.installment Date.new(2026, 9, 1), "100.00"
          end
        end
      })

      expect(found).to include(
        a_string_including("the components add up to 400.0, not the contract's 500.0 (F58, rej. 746)"),
        a_string_including("installment 001 is due before the manifest's emission (F60, rej. 736)"),
        a_string_including("installment 002 is not due after the one before it (F61, rej. 737)"),
        a_string_including("installments plus advance add up to 200.0, not the contract's 500.0 (F62, rej. 738)")
      )
    end

    it "keeps installments and advances out of a cash payment" do
      found = issues_of(carrier { |mdfe|
        mdfe.road { |road| road.freight_payment(tax_id: "11222333000181", total: "10.00", advance: "1.00", components: [{kind: :freight, amount: "10.00"}], bank: {pix: "a@b.c"}, installments: [{due_on: Date.new(2026, 11, 1), amount: "9.00"}]) }
      })

      expect(found).to include(a_string_including("(F53, rej. 729)"), a_string_including("(F63, rej. 739)"))
    end
  end

  it "checks who may download the XML" do
    found = issues_of(own_cargo { |mdfe| mdfe.authorized_downloader "11222333000181", "11222333000181", "11111111111" })

    expect(found).to include("autXML: 11222333000181 is listed 2 times (F107, rej. 459)", "autXML/CPF: 11111111111 is not a valid CPF (F106, rej. 661)")
  end

  describe "the QR code" do
    let(:tree) { own_cargo.resolved }
    let(:key) { tree["@Id"].delete_prefix("MDFe") }

    it "must be there, at the portal, for this key" do
      expect(described_class.new(tree, clock: clock).issues).to include("infMDFeSupl/qrCodMDFe: the QR code's URL is required (F114, rej. 480)")
      expect(described_class.new(tree, qr_code: "https://example.com/qr?chMDFe=#{key}&tpAmb=2", clock: clock).issues)
        .to include("infMDFeSupl/qrCodMDFe: the address must be https://dfe-portal.svrs.rs.gov.br/mdfe/qrCode (F115, rej. 479)")
      expect(described_class.new(tree, qr_code: "#{DfeRb::Mdfe::QrCode::URL}?chMDFe=#{document_key(58)}&tpAmb=2", clock: clock).issues)
        .to include(a_string_including("(F116, rej. 481)"))
    end

    it "carries a signature in contingency only" do
      signed = "#{DfeRb::Mdfe::QrCode::URL.upcase}?chMDFe=#{key}&tpAmb=2&sign=abc="
      contingency = Marshal.load(Marshal.dump(tree)).tap { |copy| copy["ide"]["tpEmis"] = 2 }

      expect(described_class.new(tree, qr_code: signed, clock: clock).issues).to eq(["infMDFeSupl/qrCodMDFe: `sign` is for a manifest in contingency only (F118, rej. 488)"])
      expect(described_class.new(contingency, qr_code: signed.sub(/&sign.*/, ""), clock: clock).issues)
        .to include("infMDFeSupl/qrCodMDFe: a manifest in contingency signs its key in `sign` (F117, rej. 482)")
    end
  end
end
