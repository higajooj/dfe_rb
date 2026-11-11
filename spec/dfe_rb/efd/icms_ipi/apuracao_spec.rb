RSpec.describe DfeRb::Efd::IcmsIpi::Apuracao do
  it "works out the ICMS to pay from debits, credits and the adjustments by their code" do
    e110 = described_class.e110(debits: 1000, credits: 400, previous_credit: 100,
      adjustments: [{code: "MS020001", amount: 50}, {code: "MS000001", amount: 30}, {code: "MS040001", amount: 80}, {code: "MS050001", amount: 5}])

    expect(e110).to include(vl_tot_debitos: 1000, vl_tot_aj_debitos: 30, vl_tot_creditos: 400, vl_tot_aj_creditos: 50, vl_sld_credor_ant: 100,
      vl_sld_apurado: 480, vl_tot_ded: 80, vl_icms_recolher: 400, vl_sld_credor_transportar: 0, deb_esp: 5)
  end

  it "carries a credit balance, and the deductions beyond what is due" do
    expect(described_class.e110(debits: 100, credits: 300)).to include(vl_sld_apurado: 0, vl_icms_recolher: 0, vl_sld_credor_transportar: 200)
    expect(described_class.e110(debits: 100, credits: 0, adjustments: [{code: "MS040001", amount: 150}]))
      .to include(vl_sld_apurado: 100, vl_icms_recolher: 0, vl_sld_credor_transportar: 50)
  end

  it "refuses an adjustment of another apuração or kind" do
    expect { described_class.e110(debits: 0, credits: 0, adjustments: [{code: "MS120001", amount: 1}]) }.to raise_error(ArgumentError, /MS120001/)
  end

  it "works out the ST, DIFAL and IPI of a state" do
    expect(described_class.e210(retention: 300, returns: 20, previous_credit: 10))
      .to include(ind_mov_st: "1", vl_sld_dev_ant_st: 270, vl_icms_recol_st: 270, vl_sld_cred_st_transportar: 0)
    expect(described_class.e310(difal: {debits: 24}, fcp: {debits: 4, previous_credit: 10}))
      .to include(ind_mov_fcp_difal: "1", vl_recol_difal: 24, vl_recol_fcp: 0, vl_sld_cred_transportar_fcp: 6)
    expect(described_class.e520(debits: 10, credits: 25)).to include(vl_sc_ipi: 15, vl_sd_ipi: 0)
  end
end
