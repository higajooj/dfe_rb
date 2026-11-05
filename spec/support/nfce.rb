# Shared helpers for the NFC-e specs: an issuer in MS and a ready-to-sign consumer sale.
module NfceHelpers
  NFCE_ISSUER = {
    tax_id: "11.444.777/0001-61", name: "EMPRESA TESTE LTDA", state_registration: "282567143", tax_regime: :simples,
    address: {street: "Rua A", number: "100", district: "Centro", city_code: "5002704", zip: "79002000"}
  }.freeze

  def nfce_client(transport, **options)
    DfeRb::Nfce::Client.new(certificate: nfe_certificate, uf: "MS", transport: transport, sleeper: ->(_seconds) {}, **options)
  end

  # A sale of one item for 8.50, paid in cash. Pass the builder's options (certificate:,
  # environment:, clock:...), the item's fields to change (item:, icms:) and change the
  # rest in the block.
  def nfce_invoice(builder = nil, number: 1, payment: [:money], item: {}, icms: {csosn: "102", origin: :domestic}, **options, &block)
    fields = {code: "1", description: "Cafe", ncm: "09012100", cfop: "5102", unit: "UN", quantity: 1, unit_price: "8.50"}.merge(item)
    fill = lambda do |nfce|
      nfce.series 1
      nfce.number number
      nfce.nature_of_operation "Venda ao consumidor"
      nfce.issuer(**NFCE_ISSUER)
      nfce.item do |i|
        i.__assign(fields)
        i.icms(**icms)
        i.pis cst: "07"
        i.cofins cst: "07"
      end
      nfce.payment(*payment) if payment
      block&.call(nfce)
    end
    builder ? builder.build_invoice(**options, &fill) : DfeRb::Nfce::Invoice.new(**options, &fill)
  end
end

RSpec.configure do |config|
  config.include NfceHelpers
end
