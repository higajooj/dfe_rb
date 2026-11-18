RSpec.describe DfeRb::Nfse::Validator do
  let(:clock) { Struct.new(:now).new(Time.utc(2026, 11, 18, 14, 30)) }

  def issues(layout: :nt009, &block) = service_declaration(clock: clock, layout: layout, &block).issues

  it "accepts the ready declaration in both layouts" do
    expect(issues).to eq([])
    expect(issues(layout: :v1_01)).to eq([])
  end

  it "keeps the provider issuing the DPS to its CNPJ and regime: the Sefin reads the rest" do
    found = issues { |d| d.provider name: "ACME LTDA", address: taker_address }

    expect(found).to include(a_string_matching(/E0121/), a_string_matching(/E0128/))
  end

  it "checks the parties' check digits and the taker's address" do
    found = issues do |d|
      d.provider cnpj: "11444777000162"
      d.taker cnpj: "11222333000182"
    end

    expect(found).to include(a_string_matching(/prest\/CNPJ.*E0080/), a_string_matching(/toma\/CNPJ.*E0188/))
    expect(issues { |d| d.taker["end"] = nil }).to include(a_string_matching(/E0235/))
    expect(issues { |d| d.taker cnpj: NfseHelpers::PROVIDER }).to include(a_string_matching(/E0202/))
  end

  it "checks the Simples Nacional and special regimes against rates and withholdings" do
    expect(issues { |d| d.provider simples_regime: nil, simples: :none }).to include(a_string_matching(/E0162/))
    expect(issues { |d| d.prest["regTrib"].delete("regApTribSN") }).to include(a_string_matching(/E0166/))
    expect(issues { |d|
      d.iss_rate "2.00"
      d.provider special_regime: :self_employed
    }).to include(a_string_matching(/E0604/))
    expect(issues { |d| d.iss_rate "6.00" }).to include(a_string_matching(/more than 5%.*E0595/))
    mei = issues do |d|
      d.prest["regTrib"].delete("regApTribSN")
      d.provider simples: :mei
      d.iss_rate "2.00"
      d.withholding :taker
    end
    expect(mei).to include(a_string_matching(/E0600/), a_string_matching(/E0583/), a_string_matching(/E0710/))
  end

  it "refuses a rate or a withholding on a service the ISSQN doesn't tax" do
    found = issues do |d|
      d.issqn :immune
      d.iss_rate "2.00"
      d.withholding :taker
    end

    expect(found).to include(a_string_matching(/E0580/), a_string_matching(/E0602/))
  end

  it "checks the values against the service's" do
    found = issues do |d|
      d.unconditional_discount "1000.00"
      d.values { |v| v.base_adjustment rate: "150.00" }
    end

    expect(found).to include(a_string_matching(/vDescIncond.*E0431/), a_string_matching(/E0453/))
  end

  it "checks the PIS and the COFINS against their base and rates" do
    found = issues do |d|
      d.federal pis_cofins: {cst: "01", base: "1000.00", pis_rate: "0.65", pis: "7.00", cofins_rate: "3.00", cofins: "30.00", withholding: :pis_cofins_csll}
    end

    expect(found).to include(a_string_matching(/vPis: 7.0 is not.*\(6.5\) \(E0694\)/), a_string_matching(/E0724/))
    expect(found).not_to include(a_string_matching(/E0696/))
  end

  it "asks for the approximate taxes the provider's regime allows" do
    expect(issues { |d| d.approximate_taxes :not_informed }).to include(a_string_matching(/E0712/))
    expect(issues { |d|
      d.provider simples: :none, simples_regime: nil
      d.prest["regTrib"].delete("regApTribSN")
    }).to include(a_string_matching(/E0713/))
    expect(issues { |d| d.valores["trib"].delete("totTrib") }).to include(a_string_matching(/give the approximate taxes/))
  end

  it "asks for the groups some services carry" do
    expect(issues { |d| d.service national_code: "070201" }).to include(a_string_matching(/E0370/))
    expect(issues { |d| d.service national_code: "120101" }).to include(a_string_matching(/E0390/))
    expect(issues { |d| d.service municipal_code: "000" }).to include(a_string_matching(/E0315/))
  end

  it "checks the series, the dates and the replaced note's reason" do
    expect(issues { |d| d.series 50_000 }).to include(a_string_matching(/E0010/))
    expect(issues { |d| d.service_date Date.new(2026, 11, 19) }).to include(a_string_matching(/E0015/))
    expect(issues { |d| d.replaces nfse_key, reason: :other }).to include(a_string_matching(/E0078/))
  end

  it "refuses a city outside the IBGE table" do
    expect(issues { |d| d.service city_code: "5002799" }).to include(a_string_matching(/cLocPrestacao: 5002799.*E0302/))
  end

  it "requires the IBS/CBS from October 2026 under NT 009, the Simples Nacional's from 2027" do
    regular = issues do |d|
      d.__data.delete("IBSCBS")
      d.provider simples: :none
      d.prest["regTrib"].delete("regApTribSN")
      d.approximate_taxes federal: "100.00", state: "0", municipal: "20.00"
    end

    expect(regular).to include(a_string_matching(/01\/10\/2026.*E0855/))
    expect(issues { |d| d.__data.delete("IBSCBS") }).to eq([])
    expect(issues(layout: :v1_01) { |d| d.__data.delete("IBSCBS") }).to eq([])
  end

  it "checks the IBS/CBS group's own consistency" do
    found = issues do |d|
      d.ibs_cbs class_code: "200001", recipient_indicator: 1, operation_type: :prepaid
      d.serv["cServ"].delete("cNBS")
    end

    expect(found).to include(a_string_matching(/E0959/), a_string_matching(/E0910/), a_string_matching(/E0904/), a_string_matching(/E0905/))
  end
end
