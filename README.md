> ⚠️ Actively evolving. Breaking changes are the norm!

# dfe_rb

Ruby client for the Brazilian SEFAZ DF-e web services, with an A1 certificate.

- **Emit NF-e** (modelo 55, layout 4.00) in production and homologação: build, validate, sign, authorize, consult, cancel, correct (CC-e) and inutilize. IBS/CBS (Reforma Tributária) included.
- **Distribution** (`NFeDistribuicaoDFe`) and **recipient manifestation** events: `DfeRb::Dfe` and `DfeRb::Manifest`.

Not covered yet: NFC-e (modelo 65), contingency (SVC, EPEC, offline), DANFE printing, other DF-e (CT-e, MDF-e, NFS-e).

```ruby
gem "dfe_rb", github: "higajooj/dfe_rb", tag: "v0.2.0"
```

Ruby 3.3+. Official terms are kept where there is no good translation (*homologação*, *chave de acesso*, *inutilização*, *protocolo*); the field names below are English, and every field is also reachable by its official tag name.

## Quick start

```ruby
require "dfe_rb"

certificate = DfeRb::Certificate.from_pkcs12(File.binread("empresa.pfx"), "password")
client = DfeRb::Nfe::Client.new(certificate: certificate, uf: "SP")   # homologação unless told otherwise

client.status.online?   # => true

invoice = client.build_invoice do |nfe|
  nfe.series 1
  nfe.number 1234
  nfe.nature_of_operation "Venda de mercadoria"
  nfe.issuer tax_id: "12.345.678/0001-95", name: "ACME LTDA", state_registration: "111111111111", tax_regime: :simples,
    address: {street: "Rua A", number: "100", district: "Centro", city_code: "3550308", city: "Sao Paulo", state: "SP", zip: "01001000"}
  nfe.recipient cnpj: "11.222.333/0001-81", name: "Cliente SA",
    address: {street: "Rua B", number: "1", district: "Centro", city_code: "3304557", city: "Rio de Janeiro", state: "RJ", zip: "20000000"}
  nfe.item do |i|
    i.code "SKU-1"
    i.description "Widget"
    i.ncm "84713012"
    i.cfop "6102"
    i.unit "UN"
    i.quantity 2
    i.unit_price "10.00"
    i.icms csosn: "102", origin: :domestic
    i.pis cst: "07"
    i.cofins cst: "07"
  end
  nfe.payment :money, "20.00"
end

signed = client.sign(invoice)   # validates, then signs. Store signed.xml BEFORE sending.
result = client.authorize(signed)

if result.authorized?
  File.write(result.filename, result.proc_xml)   # "<chave>-procNFe.xml": what you archive and send to the recipient
else
  puts "#{result.code} #{result.message}"
end
```

`homologação` is the default because notes issued there have no fiscal value; pass `environment: :production` to issue real ones. In homologação the recipient name is replaced with the text SEFAZ requires (rej. 598).

## What you provide, what the gem derives

You provide the facts of the operation: parties, items, per-item tax values (`vBC`, `pICMS`, `vICMS`, IBS/CBS...), payments, the number and series. The gem does not calculate taxes and does not store numbering.

The gem fills in and derives: `cUF`, `mod`, `tpEmis`, `tpAmb`, `finNFe`, `indPres`, `procEmi`, `verProc`, the issue time (in the issuer's UTC offset), the random `cNF`, the check digit, the `Id`/chave de acesso, `idDest`, `indIEDest` (`"ISENTO"` is understood), `indFinal`, `cEAN`/`cEANTrib` (`SEM GTIN`), `uTrib`/`qTrib`/`vUnTrib`, `vProd`, every total (`ICMSTot`, `IBSCBSTot`, `vNF`), `vTroco`, `modFrete`. Anything you set yourself is kept. `cNF` and the issue time are generated once per invoice, so building the XML twice gives the same document.

## Taxes

```ruby
i.icms  cst: "00", origin: 0, base_mode: 3, base: "300.00", rate: "18.00", amount: "54.00"   # => <ICMS00>
i.icms  csosn: "500", origin: 0                                                              # => <ICMSSN500>
i.icms  cst: "10", ..., operation_base_rate: "100.00", st_state: "RJ"                        # => <ICMSPart>
i.ipi   cst: "50", base: "300.00", rate: "5.00", amount: "15.00"                              # => <IPI><IPITrib>
i.pis   cst: "01", base: "300.00", rate: "1.65", amount: "4.95"                               # => <PISAliq>
i.cofins cst: "07"                                                                            # => <COFINSNT>
i.ibs_cbs cst: "000", class_code: "000001", base: "300.00",
          ibs_uf: {rate: "0.10", amount: "0.30"}, ibs_municipal: {rate: "0", amount: "0"}, cbs: {rate: "0.90", amount: "2.70"}
```

The XML group comes from the CST/CSOSN. Regime normal (`tax_regime: :normal`) must carry IBS/CBS on ordinary notes; the CST and `cClassTrib` codes come from the Portal Nacional tables (the gem checks their format, not their meaning).

## Other ways to describe an invoice

```ruby
client.build_invoice(number: 1, issuer: {...}, items: [{code: "1", description: "Widget", ...}])   # hash
i.c_prod "SKU-1"; i.xProd "Widget"   # inside an item, every field also answers to its official tag: c_prod, "cProd", x_prod...
client.sign(File.read("nfe.xml"))   # raw <NFe> XML from another system: checked, signed, sent as is
```

Unknown names fail with a suggestion (`nature_of_operacion` → did you mean `nature_of_operation`?), and symbols map to codes (`tax_regime: :normal`, `payment :pix, ...`, `presence: :internet`).

## Lots, results and errors

```ruby
results = client.authorize([signed_a, signed_b])   # 2..50 notes: asynchronous lot, polled until processed
client.authorize(signed).status                    # :authorized, :authorized_late, :authorized_with_alert, :denied, :rejected, :pending
client.authorize!(signed)                          # raises DfeRb::Nfe::Rejected / Denied / ConsumptionBlocked instead
```

A rejection is a *result* (SEFAZ answered "no"); exceptions are for problems: `DfeRb::ValidationError` (`#issues` lists everything wrong locally, nothing was sent), `DfeRb::TransportError` (`#maybe_processed?` tells whether SEFAZ may have acted), `DfeRb::CertificateError`, `DfeRb::Nfe::Conflict`.

Lost answers are handled for you: after a timeout that may have reached SEFAZ, or a duplicate rejection (204/539), the gem asks for the key. If SEFAZ holds this same document it returns its protocol (`result.recovered?`); if it holds a different one, `Conflict` is raised; if it holds nothing, the original error is re-raised and the *same signed XML* can be sent again. This is why you must store `signed.xml` first and never rebuild a note that may have been sent.

## After authorization

```ruby
client.consult(key)                                              # => ConsultResult (status, protocol, events)
client.cancel(key, protocol: result.protocol, reason: "Erro na digitação dos dados")   # 110111, up to 24 h
client.correct(key, text: "Corrigir o endereço de entrega", sequence: 1)               # CC-e 110110
client.inutilize(series: 1, from: 10, to: 12, reason: "Numeração pulada por erro")
event.proc_xml                                                   # procEventoNFe to archive
```

## Advanced

```ruby
DfeRb::Nfe::Client.new(certificate: cert, uf: "SP",
  endpoints: {authorization: "https://proxy.internal/nfe"},       # override any URL
  timeouts: {open: 10, read: 90}, logger: Rails.logger,
  transport: MyTransport.new)                                     # anything with #post(endpoint, xml)
client.sign(invoice, strict: false)                               # skip the business rules (schema and formats always apply)
client.raw(:consult, xml)                                         # any service: :status :authorization :authorization_return :consult :inutilization :event
DfeRb::Nfe::Endpoints.resolve(uf: "MA", environment: :production, service: :status)
DfeRb.logger = Logger.new($stdout)                                 # SOAP traffic; certificates and signatures are filtered out
```

Certificates: A1 only, from a `.pfx` (`DfeRb::Certificate.from_pkcs12`), PEM, or OpenSSL objects you already hold (`DfeRb::Certificate.new(certificate:, private_key:, chain: [])`). Files encrypted with RC2-40 (common in ICP-Brasil A1) are opened through the OpenSSL legacy provider, which is loaded only while parsing.

## Testing

`bundle exec rake` runs the specs (no network) and Standard. Live checks against homologação are opt-in:

```sh
DFE_RB_LIVE=1 DFE_RB_PFX=empresa.pfx DFE_RB_PFX_PASSWORD=... bundle exec rspec spec/live
```

They confirm the SOAP contract and every service with your certificate. The full lifecycle example (authorize, consult, correct, cancel, inutilize) also needs an issuer registered at the state: see the header of `spec/live/nfe_homologacao_spec.rb`.

## Legislation

Built from MOC 7.0 (Anexo I v7.03) and the NTs up to NT 2026.009, with the layout read from the `PL_010f_v1.04` schema package. Where the MOC and later NTs disagree, the NTs and the schema win (synchronous authorization of single-note lots, 7-day late-issue window, 4-digit `cStat`, alphanumeric CNPJ).
