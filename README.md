> ⚠️ Actively evolving. Breaking changes are the norm!

# dfe_rb

Ruby client for the Brazilian SEFAZ DF-e web services, with an A1 certificate.

- **Emit NF-e** (modelo 55, layout 4.00) in production and homologação: build, validate, sign, authorize, consult, cancel, correct (CC-e) and inutilize. IBS/CBS (Reforma Tributária) included.
- **Distribution** (`NFeDistribuicaoDFe`) and all four **recipient manifestations** through `DfeRb::Nfe::Distribution::Client`: typed metadata, exact decoded XML, cooldown advice and signed events ready to archive.
- **Contingency**: the SEFAZ Virtuais de Contingência (SVC-AN, SVC-RS) and the EPEC.
- **Consulta cadastro**: a taxpayer's state registration, situation and address, from the state itself.
- **Emit NFC-e** (modelo 65, layout 4.00) through `DfeRb::Nfce::Client`: the same builder, with the QR code version 3 (no CSC), its off-line contingency, the cancellation by substitution and the rules of modelo 65. See [NFC-e](#nfc-e).
- **Emit MDF-e** (modelo 58, layout 3.00), all four modals: build, validate, sign, authorize, consult, cancel, close, add drivers and documents, off-line contingency, and its distribution service. See [MDF-e](#mdf-e).
- **Write the EFD ICMS/IPI** (SPED Fiscal) of a period: its registers, the blocks' openings and closings and Block 9, an NF-e's or NFC-e's C100, C101, C170 and C190 from its XML, and the apurações of Block E. See [EFD ICMS/IPI](#efd-icmsipi).
- **Write the EFD-Contribuições** (PIS/Pasep and COFINS) of a period up to December 2026: its registers, an NF-e's C100 and C170 or an NFC-e's C175 with their PIS and COFINS, the apuração of Block M and the credits carried in Block 1. See [EFD-Contribuições](#efd-contribuições).

Not covered yet: the NFC-e's EPEC (NT 2014.003) and QR code version 2 (with CSC), off-line and paper contingency of the NF-e (`tpEmis` 9, FS-DA), other DF-e (CT-e, NFS-e), the DAMDFE and the MDF-e's ANTT payment events.

```ruby
gem "dfe_rb", github: "higajooj/dfe_rb", tag: "v0.14.0"
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

You provide the facts of the operation: parties, items, the tax treatment (CST) and the rates state law sets, payments, the number and series. The gem does not choose a tax treatment and does not store numbering.

The gem fills in and derives: `cUF`, `mod`, `tpEmis`, `tpAmb`, `indPres`, `procEmi`, `verProc`, the issue time (in the issuer's UTC offset), the random `cNF`, the check digit, the `Id`/chave de acesso, `idDest`, `indIEDest` (`"ISENTO"` is understood), `indFinal`, `cEAN`/`cEANTrib` (`SEM GTIN`), `uTrib`/`qTrib`/`vUnTrib`, `vProd`, every total (`ICMSTot`, `IBSCBSTot`, `ISTot`, `vNF`, `vNFTot`), `vItem`, `vTroco`, `modFrete`, plus:

- **Bases the item's own values fix**, once you give what makes the item taxed (the rate; a `base_reduction` or `st_margin` when there is one). The operation value is `vProd + vFrete + vSeg + vOutro - vDesc`:
  - ICMS `vBC` (LC 87/1996, art. 13): the operation value, with the IPI when the recipient is a final consumer, less `pRedBC`; `modBC` 3. A CST that is always taxed (00, 10, 20, 70) on an interstate sale needs neither base nor rate.
  - `vBCFCP` = `vBC`, and `vBCFCPST` = `vBCST`, when their FCP rate is given.
  - `vBCST` from `st_margin` (`pMVAST`): (operation value + IPI) x (1 + MVA), less `pRedBCST` (Conv. ICMS 142/2018); `modBCST` 4. A state that composes its ST base otherwise gives `st_base`.
  - DIFAL: `vBCUFDest` is the operation value with the IPI, and `vBCFCPUFDest` the same.
  - IPI `vBC`: the operation value (not for a per-unit IPI).
  - PIS and COFINS `vBC`, when a rate is given: the operation value less the item's own ICMS (STF Tema 69, Lei 14.592/2023).
  - `vCredICMSSN` = operation value x `pCredSN` (CSOSN 101, 201, 900).
- **Invoice-level amounts spread over the items**: `nfe.freight`, `nfe.insurance`, `nfe.discount` and `nfe.other_expenses` are split in proportion to each item's `vProd`, to the cent (the shares always add up), before any tax is computed. An item that sets its own takes no share.
- **Tax values whose result the validation rules fix** (base × rate, ±0.01 tolerance): `vICMS`, `vFCP`, `vICMSOp`/`vICMSDif` (CST 51), `vICMSST` from `vBCST`, `vFCPST`, `vFCPSTRet`, `vIPI`, `vPIS`/`vCOFINS` (by rate or quantity), DIFAL (`vFCPUFDest`, `vICMSUFDest`, `vICMSUFRemet`), `vIS`, and IBS/CBS: the base (RV UB16-10), `vDif`, `pAliqEfet`, `vIBSUF`, `vIBSMun`, `vIBS`, `vCBS`.
- **Rates fixed by law**, on a normal operation (`finNFe` 1). That covers the interstate `pICMS`/`pICMSInter` (4%, 7% or 12% by states and origin), `pICMSInterPart` by year, the IBS/CBS standard rates of the issue year (IT 2025.002; a rate the law hasn't set yet is left for you to give), and `pIPI` from the TIPI line of the item's `NCM` and `EXTIPI` when you give `i.ipi` a base without a rate (an NT line and a per-unit IPI get none). A return, complement or adjustment carries the rates of the operation it refers to, so you give them. So does an item with a retorno or anulação CFOP (`6916`, `6206`...), for the interstate ICMS rates.
- **Official tables** (shipped in `lib/dfe_rb/nfe/data`, refreshed by `script/update_tables`):
  - the IBS/CBS `CST` and rate reduction (`gRed`) from `class_code` (cClassTrib), zero main rates for a classification taxed in `gTribRegular`, and no IBS/CBS amounts for a deferral CST until you give its `gDif`
  - an address's `xMun` from `cMun`, `cMun` from `xMun` + `UF`, or `UF` from `cMun` (IBGE)
  - each CFOP's indicators (IT 2023.002), through `DfeRb::Nfe::Tables.cfop("6916")`

  - the CESTs of Conv. ICMS 142/2018, each wording with its days in force and the NCMs it is listed for, through `DfeRb::Nfe::Tables.cest("2104600")`

  `script/update_tables --cfop <file.xlsx>` regenerates the CFOP table from the `.xlsx` the Portal Nacional da NF-e publishes, and `--tipi <Tipi.xlsx>` regenerates the TIPI from the Receita Federal's.
- **Operation-dependent codes**: a 3-digit CFOP (`"102"`) gets the first digit the operation calls for (`5102`, `6102`, `7102`, or `1`/`2`/`3` on entries). `finNFe` is 5 with a `credit_note_type` (`tpNFCredito`), 6 with a `debit_note_type`, otherwise 1. `tpNF` is 0 (entry) on a credit note or when every item has an entry CFOP (`1102`), otherwise 1. The gem flags a devolução CFOP (`5202`) on a note that isn't a return (rej. 328). Give `purpose :return` yourself, since a complement of a return (`:complementary`) takes the same CFOPs.
- **Billing and payment**: a single payment without amount pays `vNF` (0.00 for tPag 90/91); `fat/vOrig` defaults to `vNF`, `vLiq` to `vOrig - vDesc`, a single installment to `vLiq`, and installments are numbered `001`, `002`...
- **Responsável técnico**: `technical_contact:` on the `Client` (or `Invoice.new`) fills `infRespTec` on every invoice and, with `csrt:`, its `hashCSRT` (NT 2018.005). The CSRT never goes into the XML.

**State law is always yours to give.** The gem derives only what federal law or a national table fixes. It never fills in what each state's ICMS regulation decides: the internal `pICMS` of a product, base reductions (`pRedBC`, `pRedBCST`), benefit codes (`cBenef`) and presumed credits (`gCred`), FCP rates (`pFCP`, `pFCPST`, `pFCPUFDest`), the ST margin (`pMVAST`), the destination's internal rate (`pICMSUFDest`), or the ICMS CST itself. SEFAZ mostly doesn't check these, so a wrong value is usually authorized. The gem ships no state table either (internal and FCP rates, cBenef x CST, presumed credit codes): those are your application's to keep.

Anything you set yourself is kept, and checked where SEFAZ checks it. `cNF` and the issue time are generated once per invoice, so building the XML twice gives the same document.

```ruby
client = DfeRb::Nfe::Client.new(certificate: certificate, uf: "SP",
  technical_contact: {cnpj: "99999999000191", contact: "Fulano", email: "dev@example.com", phone: "11999999999",
                      csrt_id: "01", csrt: ENV["CSRT"]})
```

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

# The same, derived: amounts from bases and rates, IBS/CBS from the classification and the issue year
i.icms  cst: "00", origin: 0, base_mode: 3, base: "300.00", rate: "18.00"
i.pis   cst: "01", base: "300.00", rate: "1.65"
i.ibs_cbs class_code: "200034"   # CST 200, 60% rate reduction, 2026 rates, base and amounts

# Bases derived too: give the treatment and what state law sets
nfe.freight "50.00"                                       # spread over the items by value
i.icms  cst: "00", origin: 0, rate: "17.00"               # vBC = operation value, modBC 3
i.icms  cst: "20", origin: 0, rate: "17.00", base_reduction: "41.18", fcp_rate: "2.00"
i.icms  cst: "00", origin: 0                              # interstate: 4, 7 or 12% and the base
i.icms  csosn: "101", origin: 0, credit_rate: "2.83"      # vCredICMSSN
i.pis   cst: "01", rate: "1.65"                           # vBC without the item's ICMS
i.icms_destination destination_rate: "18.00"              # DIFAL: bases, interstate rate, partition, amounts
```

An item's presumed ICMS credits go in `gCred` (NT 2019.001 v1.60), after `cBenef`, up to four per item:

```ruby
i.benefit_code "SC810001"
i.presumed_credit code: "SC850001", rate: "3.00", amount: "9.00"   # cCredPresumido, pCredPresumido, vCredPresumido
i.presumed_credit "SC850002", "1.50", "4.50"                        # the same, by position
i.presumed_credits [{code: "SC850001", rate: "3.00", amount: "9.00"}, ...]
```

The layout gives the credit no base, and each state's regulation says what the rate applies to, so `vCredPresumido` is yours to give, like the code. Whether a state accepts the group (RV I05g-10) and the code (I05h-10, Santa Catarina for now) depends on its own table, so SEFAZ checks them, not the gem.

`DfeRb::Nfe::Rates` has the federal rates you may need to pass along:

```ruby
DfeRb::Nfe::Rates.pis_cofins(:non_cumulative)                                  # => {pis: 1.65, cofins: 7.6}; :cumulative is 0.65 and 3.0
DfeRb::Nfe::Rates.simples_icms_credit(revenue_12m: "1000000.00")               # => 2.83, the pCredSN of LC 123/2006 (Anexo I)
DfeRb::Nfe::Rates.simples_icms_credit(revenue_12m: 1_000_000, annex: :industry) # => 2.86 (Anexo II); nil above the ICMS sublimit
DfeRb::Nfe::Apportion.call("10.00", %w[100 200])                               # => [3.33, 6.67]
```

The XML group comes from the CST/CSOSN. A regime normal issuer (`tax_regime: :normal`) must put IBS/CBS on every note except returns (RV UB12-10, NT 2025.002 v1.51). Homologação has rejected a note without it since 01/07/2026. In production the law has required it since 01/01/2026, but the rejection has no date yet. Nothing is asked of the Simples Nacional and the MEI, who fill it from 2027 under rules an NT has yet to bring. The CST and `cClassTrib` codes come from the Portal Nacional tables, and the gem checks their format, not their meaning.

`vNF` follows RV W16-10: exemptions are deducted per item (only where `exemption_deducted: 1`), retained monophase ICMS (`ICMS15`) is added, PIS-ST/COFINS-ST are added when the item asks for it, and ICMS-ST stays out of a direct sale of new vehicles. `payment :deferred_payment, "0.00"` is pagamento posterior (tPag 91).

## Other ways to describe an invoice

```ruby
client.build_invoice(number: 1, issuer: {...}, items: [{code: "1", description: "Widget", ...}])   # hash
i.c_prod "SKU-1"; i.xProd "Widget"   # inside an item, every field also answers to its official tag: c_prod, "cProd", x_prod...
client.sign(File.read("nfe.xml"))   # raw <NFe> XML from another system: schema + business rules, signed, sent as is
```

Unknown names fail with a suggestion (`nature_of_operacion` → did you mean `nature_of_operation`?), and symbols map to codes (`tax_regime: :normal`, `payment :pix, ...`, `presence: :internet`).

## Lots, results and errors

```ruby
results = client.authorize([signed_a, signed_b])   # 2..50 notes: asynchronous lot, polled until processed
client.authorize(signed).status                    # :authorized, :authorized_late, :authorized_with_alert, :denied, :rejected, :pending, :canceled
client.resume(result.receipt, pending_results)     # finish a lot whose answer couldn't be awaited (result.pending?)
client.authorize!(signed)                          # raises DfeRb::Nfe::Rejected / Denied / ConsumptionBlocked instead
```

A rejection is a *result* (SEFAZ answered "no"); exceptions are for problems: `DfeRb::ValidationError` (`#issues` lists everything wrong locally, nothing was sent), `DfeRb::TransportError` (`#maybe_processed?` tells whether SEFAZ may have acted), `DfeRb::CertificateError`, `DfeRb::Nfe::Conflict`.

The gem handles lost answers. After a timeout that may have reached SEFAZ, or a duplicate rejection (204/539), it asks for the key. If SEFAZ holds this same document, the gem returns its protocol (`result.recovered?`), or `:canceled` if the note was canceled since. If SEFAZ holds a different document, it raises `Conflict`. If SEFAZ holds nothing, it re-raises the original error, and the *same signed XML* can be sent again. This is why you must store `signed.xml` first and never rebuild a note that may have been sent. You can hand a stored note back as `SignedInvoice.new(xml: File.read(path), key: nil, digest_value: nil)` or as the XML itself. The gem checks it against the client's environment, certificate and signature before it goes out.

If polling an accepted lot fails, the results come back `pending?` with the lot's `receipt` (notes SEFAZ already reports are recovered by key); `client.resume(receipt, results)` collects the rest.

## After authorization

```ruby
client.consult(key)                                              # => ConsultResult (status, protocol, events)
client.cancel(key, protocol: result.protocol, reason: "Erro na digitação dos dados")   # 110111, up to 24 h
client.correct(key, text: "Corrigir o endereço de entrega", sequence: 1)               # CC-e 110110
client.inutilize(series: 1, from: 10, to: 12, reason: "Numeração pulada por erro")
event.proc_xml                                                   # procEventoNFe to archive, as event.filename ("<chave>_<tpEvento>_<seq>-procEventoNFe.xml")
```

To print the DANFE from the authorized `procNFe` XML, [browser_danfe_gen](https://github.com/higajooj/browser_danfe_gen) can be used.

## Contingency

When the issuer's SEFAZ is down, a note can't be authorized there. Anexo III gives two electronic ways out; both need a **new** note, since `tpEmis` is part of the chave de acesso.

```ruby
client.status.online?                      # the state's own authorizer
svc = client.status(contingency: true)     # its SVC: online? only while the state has it activated
svc.disabled?                              # 114: not activated; svc.deactivating? is 113

invoice = client.build_invoice do |nfe|
  # ... the same note, with a number that no transmitted note may have taken
  nfe.contingency :svc, since: outage_started_at, reason: "SEFAZ de origem fora do ar"
end
result = client.authorize(client.sign(invoice))   # goes to the SVC-AN or SVC-RS of the issuer's state
client.consult(result.key)                        # asked at the SVC, by the key's tpEmis
client.cancel(result.key, protocol: result.protocol, reason: "Erro na digitação dos dados")   # at the SVC too
```

`contingency :svc` sets `dhCont`, `xJust` and the `tpEmis` of the issuer's SVC (6 for the SVC-AN, 7 for the SVC-RS; `DfeRb::Nfe::States.contingency("MS") # => "SVC-RS"`). A note authorized there needs nothing else, because the SVC shares it with the state. Until it has, the state's own authorizer doesn't know the key. A carta de correção always goes to the state's own authorizer, since the SVC takes none, so it is rejected for a while (494). `via: :home` or `via: :contingency` on `consult`, `cancel` and `correct` picks the authorizer yourself. The SVC has no inutilização.

A note that was sent to the state before the outage and never answered must not be reissued under the same number (Anexo III 2.1.3.5): give the SVC note another number and, when the state is back, consult the old key, then cancel it if it was authorized or inutilize its number if not.

When the SVC isn't active either, the **EPEC** registers a summary of the note at the Ambiente Nacional, which is enough to print the DANFE and ship:

```ruby
invoice = client.build_invoice { |nfe| ...; nfe.contingency :epec, since: outage_started_at, reason: "SEFAZ de origem fora do ar" }
signed = client.sign(invoice)                 # tpEmis 4. Store signed.xml
event = client.prepare_epec(signed)           # store event.xml too, then:
registered = client.epec(event)               # => EventResult; registered? is cStat 136
registered.proc_xml                           # procEventoNFe to archive

client.authorize(signed)                      # later, the very same note, to the state's SEFAZ
```

The note must reach the state afterwards with the same key and the same data the EPEC carries (RV 2AB08), within the legal deadline. An EPEC can't be canceled. The state learns of the event from the Ambiente Nacional, so a note sent right after it can still be rejected with 468 for a while. Taxpayers of PR and PB can't register one (Ajuste SINIEF 25/2026), so the gem refuses it before sending.

## Consulta cadastro

```ruby
result = client.taxpayers(uf: "MS", cnpj: "24.647.331/0001-86")   # or cpf:, or ie:
result.found?                      # cStat 111 (one registration) or 112 (several); 259 is "not a taxpayer here"
taxpayer = result.taxpayers.first
taxpayer.state_registration        # "282567143"
taxpayer.active?                   # cSit 1
taxpayer.nfe_accreditation         # indCredNFe: 0 no, 1 yes, 2/3 obliged, 4 not told
taxpayer.name; taxpayer.trade_name; taxpayer.regime; taxpayer.cnae
taxpayer.address                   # {street:, number:, district:, city_code:, city:, zip:}, what the state gives
```

`uf` is the state consulted, which answers for its own taxpayers to any NF-e issuer. AM, BA, GO, MG, MS, MT, PE, PR, SP have the service, and the SVRS answers for AC, ES, PB, RN, RS and SC; for the others `taxpayers` raises `DfeRb::Nfe::Unsupported` (`DfeRb::Nfe::Endpoints.registry?(uf)` tells beforehand). It is less available than the other services (MOC 5.6.3).

## Distribution and recipient manifestation

```ruby
distribution = DfeRb::Nfe::Distribution::Client.new(
  certificate: certificate, environment: :production,
  tax_id: "11.444.777/0001-61" # optional: defaults to the certificate holder
)

batch = distribution.distribute(after: 0) # one request, at most 50 documents
if batch.success?
  batch.documents.each { |document| File.binwrite(document.filename, document.xml) }
  # Persist batch.last_nsu only AFTER storing every document successfully.
end

batch.code; batch.message
batch.last_nsu; batch.max_nsu # 15-digit strings, or nil when not supplied
batch.more?                 # true only when a sequential distribution has more documents
batch.retry_at              # advisory Time for a known cooldown, otherwise nil

distribution.fetch_nsu("42")       # one specific document; fills a known NSU gap
received_key = batch.documents.find(&:invoice?)&.key
distribution.fetch_key(received_key) if received_key # one received NF-e; excludes its events
```

This client always uses the **Ambiente Nacional**, whatever the issuer's authorizer is. The optional `uf: "MS"` sends `cUFAutor`, and leaving it out omits that field. Like the emission client, it accepts `transport:`, `endpoints:`, `timeouts:`, `logger:` and `clock:`. Endpoint overrides use `:distribution` and `:manifestation`, and `raw(service, xml)` returns the unparsed service answer. Homologação is the default. The client normalizes CNPJ punctuation and case, and accepts numeric and alphanumeric CNPJ and CPF. A company's certificate can query any branch that shares its CNPJ base, and an e-CPF can query only its own CPF. The client checks the certificate's validity and identity before each request.

Every query returns a `DistributionResult`. Its status is `:documents` (138), `:empty` (137), `:blocked` (656), `:unavailable` (108/109), or `:rejected`; `success?` is true for both 137 and 138. `distribute!`, `fetch_nsu!`, and `fetch_key!` raise `DfeRb::Nfe::Rejected` or `ConsumptionBlocked` for unsuccessful outcomes and keep the result in `error.result`. Results also expose `query` (`:dist_nsu`, `:cons_nsu`, `:cons_key`), `environment`, `application_version`, `responded_at`, `request_xml`, and `response_xml`.

Documents expose `kind`, `schema`, optional `nsu`, `key` where available, `xml`, and `filename`. The XML is the **exact decompressed content**, including its declaration and whitespace. There are five document types:

| Type | Kind | Metadata |
| --- | --- | --- |
| `InvoiceSummary` | `:invoice_summary` | `issuer_tax_id`, `issuer_name`, `state_registration`, `issued_at`, `direction`, `total`, `digest_value`, `received_at`, `protocol`, `situation_code`, `status` |
| `InvoiceDocument` | `:invoice` | Issuer identity/name, `recipient_tax_id`, issue/receipt times, `total`, `protocol`, `code`, `message` |
| `EventSummary` | `:event_summary` | `type`, `sequence`, `description`, `author_tax_id`, `authority`, `occurred_at`, `registered_at`, `protocol` |
| `EventDocument` | `:event` | Event summary metadata plus `code` and `message` |
| `UnknownDocument` | `:unknown` | Preserved XML and a safe deterministic filename |

These classes live under `DfeRb::Nfe::Distribution`. Monetary totals are `BigDecimal`, timestamps are `Time` with their source offset, and protocol numbers remain strings. Historic date-only issue dates become midnight UTC. The invoice summary's `status` is `:authorized`, `:denied`, `:canceled`, or `:unknown`. A downloaded full invoice's authorization protocol does not by itself establish its current situation, so keep the subsequent events too. `summary?`, `invoice?`, and `event?` distinguish documents. Full invoice contents remain available through XML rather than a second invoice object model.

The actual XML root decides the document type. Other valid XML is kept as `UnknownDocument`, and distributed events aren't limited to the four manifestation types. The gem never opens a schema named in a response. Invalid XML, Base64 or Gzip/CRC, conflicting protocol identities and oversized decompression raise `Distribution::InvalidResponse < DfeRb::TransportError`, carrying `response_xml`, `schema` and `nsu` where available. One bad document fails the entire batch. Each document may decompress to at most 10 MiB; change that with `max_document_bytes:`.

### Consumption rules and cursors

The gem makes **one request per call**. It doesn't sleep, paginate, retry, store cursors, enforce in-memory quotas or coordinate processes. Your application must share one ordered `ultNSU` cursor per interested party and environment across every consumer, and keep the `last_nsu` SEFAZ returns rather than deriving it from document NSUs. Document NSUs and response cursors can be absent. Targeted queries never advance your distribution cursor.

After a sequential 137, or a successful batch that reaches `max_nsu`, wait at least one hour. Any 656 also requires a one-hour wait, and another request before the hour is up restarts the block. `retry_at` counts from when the response was received locally. Targeted queries are limited to 20 per hour, so coordinate them across consumers. An empty targeted query doesn't mean sequential distribution is exhausted, so it carries no cooldown advice unless it returns 656.

Documents are available for up to 90 days after the Ambiente Nacional receives them. New consumers start generating NSUs on their first sequential query, with no retroactive generation. After more than 60 days without use, generation pauses and resumes on the next sequential query, again without backfilling the gap. A zero cursor does not guarantee recovery of every invoice from the last 90 days. Issuers retrieve distributed documents of interest, such as recipient events, rather than their own issued invoices.

### Explicit recipient manifestations

```ruby
key = received_key # select a received NF-e from your application

distribution.manifest(key, type: :awareness) # 210210: Ciência da Operação
# Choose the appropriate conclusive statement for the actual operation:
distribution.manifest(key, type: :confirmation)      # 210200
distribution.manifest(key, type: :unknown_operation) # 210220
distribution.manifest(key, type: :not_performed, reason: "Mercadoria recusada pelo destinatario") # 210240
```

These are alternative statements of the recipient's knowledge and participation. Pick the one that describes the operation. The gem never sends one while it queries or decodes documents. Awareness is optional and isn't conclusive. Awareness, confirmation and operation-not-performed can make the full XML available to the recipient, and unknown-operation doesn't unlock it. The intended workflow is to retrieve the summary, explicitly submit the right manifestation, then retrieve the newly available full XML with a later distribution or targeted query. Availability is asynchronous, and the event response alone doesn't guarantee it.

Each conclusive type accepts sequences 1 and 2, and awareness only 1. Set `sequence: 2` explicitly for a second occurrence, since the gem never increments it after a rejection or duplicate. The current NT sets awareness within 10 days of authorization and conclusive manifestations within 90 days, with its own rectification rules. Your application must decide which manifestation fits and track its legal deadlines and history, because the gem can't infer that from an access key.

For durable submission, prepare and store the signed event first:

```ruby
event = distribution.prepare_manifestation(key, type: :awareness) # UTC now; optional at: Time
File.binwrite(event.filename, event.xml)
manifestation = distribution.manifest(event)
File.binwrite(manifestation.filename, manifestation.proc_xml) if manifestation.registered?

restored = DfeRb::Nfe::Distribution::SignedManifestation.new(xml: File.binread(event.filename))
# Pass restored to manifest only when your recovery policy calls for resubmission.

confirmation = distribution.prepare_manifestation(key, type: :confirmation, sequence: 2)
responses = distribution.manifest([event, confirmation], lot_id: "123") # up to 20, one call
```

A call with a key builds and submits in one step. An array returns an array in input order, even for one element, and a single input returns one `ManifestationResult`. Prepared events can mix types. The client revalidates stored events for their author, environment, official details, signing certificate identity, signature and event ID. A renewed certificate for the same company can transmit an earlier event, as long as the embedded signing certificate was valid at the event time. The exact signed bytes are kept. `reason:` is required only for `:not_performed`, at 15 to 255 characters. Duplicate event identities within a batch are rejected locally, and you can't override the type or details of a prepared event.

Manifestation results distinguish `:registered` (135, `linked?`), `:registered_unlinked` (136), `:duplicate` (573), and `:rejected`. `registered?` includes 135/136. They expose `key`, official event `type`, `sequence`, `code`, `message`, `protocol`, `registered_at`, `event_xml`, `return_xml`, `request_xml`, and `response_xml`. Only registered answers produce `proc_xml`. `manifest!` raises for unsuccessful events, including duplicates; it does not turn a duplicate into a registration or invent its protocol. Malformed, missing, or conflicting event answers raise `InvalidResponse`.

A transport failure keeps `maybe_processed?`. A lost manifestation answer may already have registered the event, so keep the signed XML and reconcile the outcome before resubmitting. The gem doesn't retry or look up the event itself, and a distribution query whose answer was lost may still have counted against SEFAZ's consumption controls.

## NFC-e

```ruby
client = DfeRb::Nfce::Client.new(certificate: certificate, uf: "MS",   # homologação unless told otherwise
  technical_contact: {cnpj: "99999999000191", contact: "Fulano", email: "dev@example.com", phone: "11999999999"})   # MS and others require it (972)

invoice = client.build_invoice do |nfce|
  nfce.series 1
  nfce.number 1234
  nfce.nature_of_operation "Venda ao consumidor"
  nfce.issuer tax_id: "24.647.331/0001-86", name: "LOJA LTDA", state_registration: "282567143", tax_regime: :simples,
    address: {street: "Rua A", number: "100", district: "Centro", city_code: "5002704", zip: "79002000"}
  nfce.consumer cpf: "529.982.247-25"          # optional: an NFC-e may leave its consumer out
  nfce.item do |i|
    i.code "SKU-1"
    i.description "Cafe torrado 500g"
    i.ncm "09012100"
    i.cfop "5102"
    i.unit "UN"
    i.quantity 2
    i.unit_price "8.50"
    i.icms csosn: "102", origin: :domestic
    i.pis cst: "07"
    i.cofins cst: "07"
  end
  nfce.payment kind: :pix, card: {integration: :not_integrated}   # a card or PIX payment carries the card group (391)
end

signed = client.sign(invoice)        # store signed.xml before sending
result = client.authorize(signed)    # one note per request, answered synchronously
if result.authorized?
  File.write(result.filename, result.proc_xml)
  result.qr_code                     # what the DANFE NFC-e's QR code holds
  result.consult_url                 # the address it prints for looking the note up by key
end
```

It is the NF-e's builder, layout, signature, results and errors (`DfeRb::Nfce::Rejected` is `DfeRb::Nfe::Rejected`), with the NFC-e's own authorizers (AM, GO, MG, MS, MT, PR, RS and SP have theirs; every other state, BA and PE included, uses the SVRS) and these differences:

- **Defaults of a consumer sale**: `mod` 65, `tpImp` 4 (DANFE NFC-e), `indFinal` 1, `indPres` 1, `idDest` 1 and, for a consumer, `indIEDest` 9. In homologação the first item's description becomes the text RV I04-10 requires (rej. 373), as the consumer's name does (598).
- **QR code version 3** (NT 2025.001): `infNFeSupl` is built for you, with the state's QR code and consultation addresses from the Portal Nacional da NFC-e. A note issued on-line needs no CSC. Override an address with `endpoints: {qr_code: "...", consult_url: "..."}`.
- **Rules of modelo 65**, checked before sending: the CFOPs an NFC-e takes and the CST or CSOSN each goes with (with the states' own exceptions), the groups it can't carry (IPI, DIFAL, billing, vehicles, references...), home delivery, the consumer's identification above R$ 10.000,00, the payment methods it can't take and the card group of card and PIX payments (391), and the QR code's address, parameters and off-line signature. Rules each state sets (its total cap, the consumer's name and address above R$ 10.000,00, the CSOSNs it bars, home delivery, the NCMs it refuses) stay with SEFAZ.
- **One note per request**, synchronous (RV GAP03a-4): `authorize` refuses a lot of more. A lost answer or a duplicate is resolved by key, as for the NF-e.
- **Cancellation** within 30 minutes of the authorization, unless the state allows longer. There is no carta de correção (rej. 784) and no SVC (783).
- `client.sign(xml)` takes an NFC-e from another system too: an unsigned one gets its `infNFeSupl`; a signed one must already carry it.

### Off-line contingency

When the authorizer can't be reached, issue the sale off-line (`tpEmis` 9): sign it, print the DANFE NFC-e marked "EMITIDA EM CONTINGÊNCIA" and send the same signed note once SEFAZ is back, by the end of the next business day (Anexo IV).

```ruby
invoice = client.build_invoice do |nfce|
  # ... the same sale, under a number no note sent before may have taken
  nfce.contingency :offline, since: outage_started_at, reason: "Sem comunicacao com a SEFAZ"
end
signed = client.sign(invoice)        # the QR code carries the day, total and consumer, signed with the certificate
client.authorize(signed)             # later: the same key and signed XML
```

If a note sent before the outage turns out authorized too, both cover the same sale. Cancel the first by substitution (evento 110112, NT 2018.004) within 168 hours. It needs the same total, ICMS, consumer and items, and the two notes issued at most 2 hours apart:

```ruby
client.cancel_by_substitution(first.key, protocol: first.protocol, replacement: offline.key,
  reason: "Emitida em contingencia off-line para a mesma venda")
```

A note sent and never answered that SEFAZ doesn't hold is inutilized instead (`client.inutilize(series: 1, from: 20, reason: "...")`, of modelo 65).

## MDF-e

```ruby
client = DfeRb::Mdfe::Client.new(certificate: certificate, uf: "SP")   # homologação unless told otherwise

manifest = client.build_manifest do |mdfe|
  mdfe.series 1
  mdfe.number 10
  mdfe.issuer_type :own_cargo            # or :carrier, :globalized_cte
  mdfe.issuer tax_id: "12.345.678/0001-95", name: "ACME LTDA", state_registration: "111111111111",
    address: {street: "Rua A", number: "100", district: "Centro", city_code: "3550308", zip: "01001-000"}

  mdfe.load_at "Sao Paulo", "SP"         # or its IBGE code: load_at "3550308"
  mdfe.route "MG"                        # the states crossed in between, in order
  mdfe.unload_at "Goiania", "GO", nfe: ["3526...", "3526..."]

  mdfe.road do |road|
    road.vehicle plate: "ABC-1D23", tare: 9000, wheels: :truck, body: :closed, state: "SP" do |vehicle|
      vehicle.driver "Fulano de Tal", "123.456.789-09"
    end
    road.trailer plate: "XYZ1234", tare: 7000, capacity_kg: 30_000, body: :open
  end

  mdfe.cargo value: "15000.00", weight: "1200.5"     # kg, or unit: :ton
end

manifest.issues                         # every problem found locally, as messages
signed = client.sign(manifest)          # store signed.xml before sending
result = client.authorize(signed)

if result.authorized?
  File.write(result.filename, result.proc_xml)       # <key>-procMDFe.xml
  manifest.qr_code                                   # the URL for the DAMDFE's QR code
end
```

There is one authorizer for every state (the SVRS), reception is synchronous and takes one manifest per call. `authorize` returns a result whatever SEFAZ says; `authorize!` raises `DfeRb::Mdfe::Rejected`, `Unclosed` (a manifest left open stops this one) or `ConsumptionBlocked` (cStat 678). When the answer is lost or SEFAZ reports a duplicate, the client consults the key and returns the stored protocol if it is this same document (`result.recovered?`), or raises `Conflict` if it isn't.

The gem derives the access key, `cUF`, the modal and its version, `UFIni` and `UFFim` from the first loading and unloading cities, city names from the IBGE table, the document counts (`qCTe`, `qNFe`, `qMDFe`), `tpTransp` and the contractor from the traction vehicle's owner, the numbering of freight installments and the QR code. Whatever you set yourself is kept.

A carrier's manifest takes the ANTT groups by name:

```ruby
mdfe.issuer_type :carrier
mdfe.unload_at "Goiania", "GO", cte: ["3526..."]
mdfe.road do |road|
  road.rntrc "12345678"
  road.ciot "123456789012", tax_id: "12.345.678/0001-95"
  road.toll_voucher supplier: "11.222.333/0001-81", payer: "12.345.678/0001-95", amount: "50.00", kind: :tag
  road.vehicle_category "06"
  road.freight_payment tax_id: "11.222.333/0001-81", total: "1000.00", terms: :installments, advance: "200.00" do |payment|
    payment.component :freight, "1000.00"
    payment.installment Date.new(2026, 11, 10), "800.00"
    payment.bank pix: "chave@pix.com"
  end
  road.vehicle plate: "ABC1D23", tare: 9000, wheels: :tractor, body: :none do |vehicle|
    vehicle.driver "Fulano de Tal", "123.456.789-09"
    vehicle.owner tax_id: "123.456.789-09", name: "Fulano de Tal", rntrc: "87654321", kind: :tac_independent
  end
end
mdfe.insurance responsible: :issuer, insurer: {name: "SEGURADORA SA", cnpj: "11.222.333/0001-81"}, policy: "123", endorsement: "456"
mdfe.main_product "Soja", kind: :bulk_solid, ncm: "12019000", full_load: {loading: {zip: "01001000"}, unloading: {zip: "74000000"}}
```

The road modal has English names throughout. The air, water and rail modals are written and validated against their schemas too, filled by official tag or its snake_case form: `mdfe.air nac: "PRAB", matr: "PRABCD", n_voo: "AB1234", c_aer_emb: "GRU", c_aer_des: "SDU", d_voo: Date.today`, `mdfe.water ...`, `mdfe.rail { |rail| rail.trem(...); rail.vag(...) }`.

Local validation covers the layout, each modal's own schema and the rules of MOC 3.00b Anexo I that need no SEFAZ database (cities and states, issuer type against documents, keys, totals, the road and ANTT groups, the route's borders, the QR code), up to NT 2026.001's CIOT requirement. Each message names the rule and the rejection, such as `(F51, rej. 667)`. `strict: false` on `to_xml`, `issues`, `sign` and `authorize` keeps only the layout checks.

### After authorization

```ruby
client.consult(key).status                # :authorized, :canceled, :closed, :not_found or :rejected
client.unclosed.manifests                 # the issuer's manifests still open: key and protocol

client.cancel(key, protocol: result.protocol, reason: "Erro na emissao do manifesto")
client.close(key, protocol: result.protocol, city: "Goiania", state: "GO")   # or city: "5208707", or :exterior
client.add_driver(key, name: "Beltrano de Tal", cpf: "529.982.247-25", sequence: 1)
```

Each event returns an `EventResult` with `registered?`, `protocol`, `proc_xml` (the `procEventoMDFe` to archive) and `filename`. A manifest must be closed when its trip ends: one left open stops the next for the same vehicle, and any after 30 days.

A manifest issued with `mdfe.later_loading true` lists one city and no documents, and takes the NF-e as they are loaded:

```ruby
client.add_documents(key, protocol: result.protocol, load_at: "3550308",
  documents: [{nfe: "3526...", unload_at: ["Campinas", "SP"]}])
```

### Contingency

When the authorizer can't be reached, `mdfe.contingency` issues the manifest off-line (`tpEmis` 2): sign it, print the DAMDFE from it and let the cargo go. Its QR code carries the key signed with the certificate, which `client.build_manifest` supplies. Send the same signed manifest with `client.authorize` within 168 hours; the key doesn't change.

### Distribution

```ruby
distribution = DfeRb::Mdfe::Distribution::Client.new(certificate: certificate, environment: :production)

batch = distribution.distribute(after: last_nsu)    # one request, at most 50 documents
batch.documents.each { |document| File.binwrite(document.filename, document.xml) }
batch.last_nsu; batch.more?; batch.retry_at
distribution.fetch_nsu("42")                        # one specific document
```

It returns MDF-e (`ManifestDocument`) and their events (`EventDocument`) of interest to the certificate's holder that someone else issued, such as those naming it in `autXML`, with the same results, cursor rules and failure handling as the NF-e's distribution. A consumption block is cStat 678 here.

## EFD ICMS/IPI

`DfeRb::Efd::IcmsIpi` writes the EFD ICMS/IPI (SPED Fiscal) a taxpayer delivers each month, the file its accountant imports into the PVA, validates, signs and transmits. The registers follow the Guia Prático (Ato COTEPE/ICMS 44/2018); `Version.for(last_day)` gives `COD_VER`, for periods from 2020 to 2026.

```ruby
efd = DfeRb::Efd::IcmsIpi
file = efd::File.new
file.add "0000", cod_ver: efd::Version.for(last_day), cod_fin: 0, dt_ini: first_day, dt_fin: last_day, nome: "ACME LTDA",
  cnpj: "12345678000195", uf: "MS", ie: "283456789", cod_mun: "5002704", ind_perfil: "A", ind_ativ: 1
file.add "0005", fantasia: "ACME", cep: "79002000", end: "Rua A", bairro: "Centro"

note = efd::Note.new(nfe_proc_xml, informant: "12345678000195")
items = note.own? ? note.items : note.items.map { it.on_entry(cfop: "1102", icms_credit: 18) }
c100 = file.add("C100", note.c100(items:, participant: note.participant&.dig(:cod_part), entry_date:, period_end: last_day))
c100.add("C101", note.c101) if note.own? && note.c101
efd::Analytic.c190(items).each { c100.add("C190", it) }
file.add "0150", note.participant

e110 = efd::Apuracao.e110(debits: 1000, credits: 400, previous_credit: 0, adjustments: [{code: "MS020001", amount: 50}])
file.add("E100", dt_ini: first_day, dt_fin: last_day).add("E110", e110)

File.binwrite("efd.txt", file.to_latin1)   # ISO-8859-1, "|" between fields, CR LF
```

- **Registers** are added at their level: those right below a block's opening on the file, the others under their parent (`c100.add "C190", ...`), by the lowercase names of their fields. The file orders them by block and code, opens and closes every block (`X001` with or without data, `X990` with its count, Block B and the empty ones included) and writes Block 9 (`9900` for each register, `9990`, `9999`). `to_s` raises `DfeRb::ValidationError` with every field it can't write: a required one blank, a number too long, a CNPJ or key of the wrong size.
- **Fields** are written as the layout asks: decimals with a comma and their places, dates `ddmmaaaa`, codes with their leading zeros, text without `|` and in Latin-1 (what isn't becomes its nearest kin).
- **A note** (`Note`) gives its participant (0150), its C100 (only the identity of a canceled one, COD_SIT 02; no participant nor ST, IPI, PIS and COFINS for an NFC-e), its C101 (DIFAL and FCP to a non-contributor, EC 87/15) and, received, the C170 of each item in the recipient's code and unit. Its `items` carry the document's values, the FCP with its ICMS; `Item#on_entry` books one as its recipient does: its CFOP of entry, the ICMS credit taken (none, or the amount), the IPI and ST it takes no credit for added to the item's value, and its CST from its own view (60 for ST with no credit, 90 from a Simples Nacional supplier). Following the Guia, a note the informant issued carries only C100 and C190; one it received, C170 too.
- **The analytic records** (`Analytic.c190`) sum items by CST, CFOP and ICMS rate, with the operation value (`VL_OPR`: goods, freight, insurance, other expenses, ST and IPI, less the discount) and the base the reduction left out (`VL_RED_BC`); the C100's totals are theirs.
- **Apurações** (`Apuracao`): `e110` from the period's debits and credits, the credit carried over and the E111 adjustments by their code (the state, `0`, then 0 other debits, 1 credits reversed, 2 other credits, 3 debits reversed, 4 deductions, 5 special debits); `e210` (ST of a state), `e310` (DIFAL and FCP of a state) and `e520` (IPI), each as the Guia's validations state them.

Not covered yet: Blocks D, G and K (they go out empty), C110 to C197, 0400 to 0460, the registers of other documents (CT-e, energy, communication) and the leiaute 021 of 2027.

## EFD-Contribuições

`DfeRb::Efd::Contribuicoes` writes the EFD-Contribuições a company under the lucro real (non-cumulative) or presumido (cumulative) delivers each month for PIS/Pasep and COFINS, by the Guia Prático (versão 1.35). `Version.for(last_day)` gives `COD_VER` 006, from 2020 to December 2026: PIS and COFINS end then, when the CBS takes their place (LC 214/2025), and the file isn't used for later facts (Nota Técnica 011/2026).

```ruby
efd = DfeRb::Efd::Contribuicoes
file = efd::File.new
file.add "0000", cod_ver: efd::Version.for(last_day), tipo_escrit: 0, dt_ini: first_day, dt_fin: last_day, nome: "ACME LTDA",
  cnpj: "12345678000195", uf: "MS", cod_mun: "5002704", ind_nat_pj: "00", ind_ativ: 2
file.add "0110", cod_inc_trib: 1, ind_apro_cred: 1, cod_tipo_cont: 1
establishment = file.add "0140", nome: "ACME LTDA", cnpj: "12345678000195", uf: "MS", cod_mun: "5002704"
c010 = file.add "C010", cnpj: "12345678000195", ind_escri: "2"

note = efd::Note.new(nfe_proc_xml, informant: "12345678000195")
items = note.own? ? note.items : note.items.map { it.on_entry(cfop: "1102").contributions(cst: "50", base: 1000, pis_rate: "1.65", cofins_rate: "7.6") }
c100 = c010.add("C100", note.c100(items:, participant: note.participant&.dig(:cod_part), entry_date:, period_end: last_day))
if note.nfce?
  efd::Analytic.c175(items, account: "3.1.1.01").each { c100.add("C175", it) }
else
  items.each { c100.add("C170", note.c170(it, cod_item: it.code, account: "3.1.1.01")) }
end
establishment.add "0150", note.participant if note.participant

pis = efd::Apuracao.new(:pis, regime: :non_cumulative, cnpj: "12345678000195", month: first_day)
pis.revenue(cst: "01", rate: "1.65", revenue: 10_000, base: 9_000)
pis.untaxed(cst: "04", nature: "003", revenue: 500)
pis.credit(cst: "50", nature: "01", base: 6_000, rate: "1.65")
pis.carried = previous_month_carry                    # [{month:, code:, apurado:, balance:}]
pis.write(file)                                       # M100 to M410 and 1100; :cofins writes M500 to M810 and 1500
pis.carry                                             # what the next month starts from

File.binwrite("efd.txt", file.to_latin1)
```

- **The file** (`File`) has the blocks 0, A, C, D, F, I, M, P and 1, ordered and counted as the EFD ICMS/IPI's: an establishment's participants, units and items go under its `0140`, its notes under its `C010`.
- **A note** (`Note`) books its C100 as the EFD ICMS/IPI does, with the PIS and COFINS of its items as booked. An NF-e's items go in C170, with each contribution's CST, base (in value with a rate in percent, or in quantity with a rate in reais) and value and the account (`COD_CTA`); an NFC-e's are summed in C175 by CFOP, CSTs and rates. Its `items` read each contribution from the document; `Item#contributions(cst:, base:, pis_rate:, cofins_rate:)` books one as its recipient does: a credit's CST (50 to 56) and base, or a CST without credit (70 to 75, 98) and nothing else.
- **The apuração** (`Apuracao`), one per contribution: the contribution of each code (table 4.3.5: 01 or 51 at the basic rate, 02 or 52 at another, 31 by ST, even at a zero rate) and rate from the revenues taxed (M210), its base reduced by table 4.3.18's codes (`reduce_base`, M215: 02 for sales given back in the cumulative regime); the credits by type (table 4.3.6) and rate (M100), each nature and CST of their base (M105), split by the month's revenue of each kind when a credit goes with more than one (CST 53 to 56, `shares:` as 0111 gives them); credits taken back (`reduce_credit`, M110, by type or by the entry CST they were taken with, split as the credits are), what the month's credit doesn't cover added to the contribution (M220); the credits of the months before spent first, oldest first, then the month's (M200 and 1100), with what is left to pay under the DCTF's code (M205: 6912-01 and 5856-01 non-cumulative, 8109-02 and 2172-01 cumulative); and the revenues without the contribution by CST and nature (M400, M410).
- **When it is due** (`Deadline.for(month)`): the 10th business day of the second month after, past the national holidays; an original file delivered later carries `0900`, with the revenue of each block. A month without revenue or credits carries `0120`, with the reason.
- **Monophase goods** (`Monophase.for(ncm)`): the group of table 4.3.10 an NCM falls in (fuels, medicines, perfumery, vehicles and chapter 87's parts, tyres, cold drinks), with the CST and nature (`NAT_REC`) a reseller books it with.

Not covered: the consolidated registers (C180 to C195, C380 to C395, C490), Blocks A, D, F, I and P (they go out empty), C110 and C120, withholdings (F600), deferral, extemporaneous credits (1101), the regime de caixa (F500) and SCPs.

## Official tables

The tables the gem derives from are yours to use too, loaded on first use and always matching the gem's release:

```ruby
cfop = DfeRb::Nfe::Tables.cfop("5.102")         # also "5102" or 5102; nil if unknown
cfop.title                                      # => "Venda de mercadoria adquirida ou recebida de terceiros, ..."
cfop.exit?, cfop.scope                          # => true, :internal (:interstate, :foreign)
cfop.valid_on?(Date.today)                      # validity from the table (valid_from, valid_until)

DfeRb::Nfe::Tables.cfops                                   # all 619, by code
DfeRb::Nfe::Tables.cfops(matching: "6.9 retorno")          # title words (case and accents ignored) and code prefix
DfeRb::Nfe::Tables.cfops.select(&:goods_return?)

DfeRb::Nfe::Tables.classification("200034")     # cClassTrib: cst, ibs_reduction, cbs_reduction, deferral?...
DfeRb::Nfe::Tables.city_name("5002704")         # => "Campo Grande"
DfeRb::Nfe::Tables.city_code("sao paulo", "SP") # => "3550308"

ipi = DfeRb::Nfe::Tables.ipi_rate("2203.00.00")         # TIPI: also "22030000"; nil if the TIPI lacks the NCM
ipi.rate, ipi.non_taxed?                                # => 3.9 (a BigDecimal, nil on an NT line), false
DfeRb::Nfe::Tables.ipi_rate("03057100", "01")           # the line of an EX (EXTIPI), else the NCM's own
DfeRb::Nfe::Tables.ipi_rates                            # all 11,107 lines, by NCM and EX

cest = DfeRb::Nfe::Tables.cest("01.001.00")            # also "0100100"; the wording in force today, nil if none
cest.ncms, cest.description                              # => ["38151210", "38151290"], "Catalisadores em colmeia ..."
cest.fits?("3815.12.10"), cest.valid_from                # => true, nil (in force from the start)
DfeRb::Nfe::Tables.cest("2104601", on: Date.new(2026, 11, 1))  # the wording of a day (nil before 01/11/2026)
DfeRb::Nfe::Tables.cests                                 # those in force today (1,040 on 15/10/2026)
DfeRb::Nfe::Tables.cests(ncm: "73084000")                # those an NCM fits, with the "outros" items (01.999.00), which list no NCM

pix = DfeRb::Nfe::Tables.payment_method("23")           # tPag: title, valid_from, deferred? (90 and 91)
pix.valid_on?(Date.new(2026, 5, 3))                     # => false: accepted from 04/05/2026
DfeRb::Nfe::Tables.payment_methods.select(&:valid_on?)  # the codes in force today
DfeRb::Nfe::Tables.card_brands                          # tBand: {"01" => "Visa", ...}

# ST margin adjusted for the interstate rate (Conv. ICMS 142/2018); the MVA and the internal rate are yours
DfeRb::Nfe::Rates.adjusted_mva("50.00", interstate: 12, internal: "17.00")   # => 59.04
```

A payment's `tPag` is checked against its table too: it must exist and be accepted on the issue date.

A CFOP's indicators, by their names in IT 2023.002:

| Method | Indicator | True when the CFOP... |
|---|---|---|
| `nfe?` | `indNFe` | may be used on an NF-e |
| `communication?` | `indComunica` | is a communication service |
| `transport?` | `indTransp` | is a transport service (the only kind `retTransp` takes) |
| `devolution?` | `indDevol` | is a devolução (the kind a return takes) |
| `goods_return?` | `indRetor` | is a retorno (no DIFAL group or interstate rates derived) |
| `annulment?` | `indAnula` | is an anulação de valor |
| `remittance?` | `indRemes` | is a remessa (no DIFAL group required) |
| `fuel?` / `fuel` | `indComb` | is a fuel operation: 1 requires the `comb` group, 2 also the carrier |
| `ibs_cbs_only?` | `indExcIBSCBS` | may be used by an issuer with no IE (IBS/CBS only) |

Before anything is sent, every item's CFOP is checked against the rules that consult the table. The messages name the CFOP's title (`6108 (Venda de mercadoria adquirida ou recebida de terceiros…)`):

- it exists, is in force on the issue date and may be used on an NF-e (I08-04, rej. 770); its first digit fits the operation (rej. 731-733)
- a return, or a credit note of type 03 or 06, carries devolução CFOPs, plus `1949`/`2949` on a return and `5949`/`6949` for natural gas (I08-140 as NT 2026.009 left it, rej. 327); a MEI's returns use only `1202`, `1553`, `2202`, `2553`, `5202` or `6202` (I08-141, rej. 1179); a devolução CFOP appears only on those notes (I08-144, rej. 328)
- an interstate sale to a final consumer who isn't an ICMS taxpayer has `icms_destination` (DIFAL), with the rule's exceptions: retorno and remessa CFOPs, `6552`/`6922`/`6929`, `ICMSPart`, exempt or untaxed ICMS, Simples Nacional, delivery in the issuer's state... (NA01-20, rej. 694)
- a fuel CFOP has the `comb` group (LA01-20, rej. 660; enforced at each state's discretion, but never wrong)
- `retTransp` takes a transport CFOP (X16-10, rej. 722)
- an issuer without IE uses only CFOPs marked `indExcIBSCBS`, except on returns (I08-191, rej. 159, NT 2026.007)

The carrier required on fuel sales with `indComb` 2 (X04-10) is left to SEFAZ: it depends on a list of ANP product codes the gem doesn't ship.

## Advanced

```ruby
DfeRb::Nfe::Client.new(certificate: cert, uf: "SP",
  endpoints: {authorization: "https://proxy.internal/nfe"},       # override any URL; also registry:, epec: and contingency: {authorization: ...}
  timeouts: {open: 10, read: 90}, logger: Rails.logger,
  transport: MyTransport.new)                                     # anything with #post(endpoint, xml)
client.sign(invoice, strict: false)                               # skip the business rules (schema and formats always apply)
client.raw(:consult, xml)                                         # any service: :status :authorization :authorization_return :consult :inutilization :event
DfeRb::Nfe::Endpoints.resolve(uf: "MA", environment: :production, service: :status)
DfeRb.logger = Logger.new($stdout)                                 # SOAP traffic; certificates and signatures are filtered out
```

What isn't particular to the NF-e sits at the top level, for the other DF-e to build on: `DfeRb::States` (IBGE codes and UTC offsets), `DfeRb::AccessKey` (the key of any model: `AccessKey.build(model: 58, ...)`), `DfeRb::Signature.sign(xml, certificate, namespace:, container:, signed:)`, `DfeRb::Schema` and `DfeRb::XmlWriter` (a layout read from its XSD and written in its namespace), `DfeRb::Formatter` and `DfeRb::Transport`, which sends the payload in the element the endpoint names with `request_tag`. So do the builder (`DfeRb::Scope`, given a document's vocabulary of names), `DfeRb::Document`, `DfeRb::Response`, `DfeRb::Cities` (the IBGE table), `DfeRb::Xsd` (validation against a bundled package) and `DfeRb::Distribution`. Their `DfeRb::Nfe` and `DfeRb::Mdfe` namesakes are the same things with each document's defaults.

The gem takes A1 certificates only, from a `.pfx` (`DfeRb::Certificate.from_pkcs12`), PEM, or OpenSSL objects you already hold (`DfeRb::Certificate.new(certificate:, private_key:, chain: [])`). Files encrypted with RC2-40 (common in ICP-Brasil A1) are opened through the OpenSSL legacy provider, which is loaded only while parsing. A precompiled Ruby (mise, rv...) whose OpenSSL can't find that provider gets it from the system's OpenSSL 3 (`openssl version -m`); set `OPENSSL_MODULES` to point elsewhere.

## Testing

`bundle exec rake` runs the specs (no network) and Standard. Live checks against homologação are opt-in:

```sh
DFE_RB_LIVE=1 DFE_RB_PFX=empresa.pfx DFE_RB_PFX_PASSWORD=... bundle exec rspec spec/live
```

They confirm the SOAP contract and every service with your certificate, including national distribution and a mixed manifestation lot. Distribution checks consume your homologação query quota and can return an existing 656 block; set `DFE_RB_LIVE_LAST_NSU` to your coordinated cursor. Optional `DFE_RB_LIVE_NSU` and `DFE_RB_LIVE_DISTRIBUTION_KEY` control targeted checks. The full lifecycle example (authorize, consult, correct, cancel, inutilize) also needs an issuer registered at the state: see the header of `spec/live/nfe_homologacao_spec.rb`. `spec/live/nfce_homologacao_spec.rb` checks every NFC-e authorizer and, with the same issuer variables, authorizes, cancels and inutilizes NFC-e, issues one off-line and cancels another by substitution; the issuer must be accredited for the NFC-e at its state. `spec/live/mdfe_homologacao_spec.rb` does the same for the MDF-e; its lifecycle (authorize, consult, add a driver, close, cancel) needs an issuer accredited for the MDF-e and an NF-e to carry, as its header says.

## Legislation

Built from MOC 7.0 (Anexo I v7.03) and the NTs up to NT 2026.009, with the layout read from the `PL_010f_v1.04` schema package. Distribution uses `PL_NFeDistDFe_104` (NT 2014.002 v1.40); recipient manifestations follow NT 2020.001 v1.60, the unchanged official manifestation detail schemas, and the generic event schemas from `PL_010d_v1.03` for alphanumeric identities. Contingency follows Anexo III of the MOC and NT 2014.001 v1.41 (EPEC), with each state's SVC taken from the Portal Nacional's "Relação de Serviços Web", which has changed since Anexo III was written; consulta cadastro follows MOC 5.6 and `PL_010d_v1.03`. Where the MOC and later NTs disagree, the NTs and the schema win (synchronous authorization of single-note lots, 7-day late-issue window, 4-digit `cStat`, alphanumeric CNPJ).

The NFC-e follows the same MOC and Anexo I, the rules each NT gives modelo 65 (NT 2015.002, 2018.004 for the cancellation by substitution, 2023.001, 2023.002 v1.01, 2023.003 v1.40, 2024.001, 2025.001 v1.03 for the QR code version 3, NT 2025.002), with the parameters of the QR code as NT 2026.003 tabulates them and Anexo IV for the off-line contingency. Where an NT lists fewer CFOPs than another, the gem takes the wider list. Its web services come from the SVRS DF-e portal's "Relação de Serviços Web" (MG, missing there, from its own authorizer's answer), and the QR code and consultation addresses from the Portal Nacional da NFC-e (`nfce.encat.org`).

The MDF-e is built from the MOC MDF-e 3.00b (with its Anexo I) and the NTs up to NT 2026.001, with the layout read from the `PL_MDFe_300b_NT012025_1.05` schema package; its distribution follows NT 2015.002 and `PL_MDFeDistDFe_100`. Its web service addresses are the SVRS portal's "Relação de Serviços Web".

## Keeping up with official publications

Everything below is a copy of something the government publishes, so it goes stale. Each change ships in a release of the gem.

Tables regenerated by `script/update_tables` (into `lib/dfe_rb/nfe/data`; `municipalities.tsv`, which the MDF-e uses too, into `lib/dfe_rb/data`):

| File | Source | How | When |
|---|---|---|---|
| `municipalities.tsv` | IBGE localities API (`servicodados.ibge.gov.br`) | downloaded on every run, or `--ibge file.json` | a municipality is created or renamed |
| `classifications.tsv` | cClassTrib table of IT 2025.002, on the SVRS DF-e portal (`dfe-portal.svrs.rs.gov.br/DFE/ClassificacaoTributaria`) | downloaded on every run, or `--svrs page.html` | each new version of the table |
| `cfop.tsv` | CFOP table of IT 2023.002, the `.xlsx` on the Portal Nacional da NF-e | `--cfop tabela.xlsx` | each new version of the IT |
| `tipi.tsv` | TIPI, the `Tipi.xlsx` on gov.br/receitafederal | `--tipi Tipi.xlsx` | each decree or ADE that changes the TIPI |

```sh
script/update_tables --cfop tabela_cfop.xlsx --tipi Tipi.xlsx
```

Every run rewrites the IBGE and SVRS tables from the network; the CFOP table and the TIPI have no stable address and are left alone unless their file is given. Review the `git diff` of the data before committing, and update the row counts the table specs assert.

Edited by hand:

| What | Where | Source | When |
|---|---|---|---|
| Payment methods (`tPag`) and the day each starts | `data/payment_methods.tsv`; friendly names in `Names::ENUMS["tPag"]`; `Tables::DEFERRED_PAYMENTS` | "Meios de pagamento" table of the Portal Nacional da NF-e (IT 2024.002) | each new version of the IT |
| Card brands (`tBand`) | `data/card_brands.tsv` | "Bandeiras" table of the Portal Nacional da NF-e | a new brand |
| XSD packages | `lib/dfe_rb/xml/schemas` (copied unchanged; versions listed in its `README.md`) | Portal Nacional da NF-e, "Esquemas XML" | each schema package (`PL_010...`), usually with an NT |
| English names of new fields | `lib/dfe_rb/nfe/names.rb` | the new schema package | with the XSDs |
| Validation and derivation rules | `validator.rb`, `calculator.rb`, `totals.rb`, `resolver.rb` (each rule cites its RV and NT) | Anexo I of the MOC and the NTs | each NT; "Legislation" above names the last one applied |
| Dates a rule starts | `Validator::IBS_CBS_SINCE` | NT 2025.002 and its successors | an NT moves a date |
| States barred from the EPEC | `States::EPEC_BARRED` | NT 2014.001 (RV 2P10-20) | an Ajuste SINIEF adds or removes a state |
| Lists a rule consults | in `validator.rb`: `MEI_RETURN_CFOPS`, `RETURN_OTHER_CFOPS`, `NATURAL_GAS_RETURN_CFOPS`, `DIFAL_EXEMPT_CFOPS`, `DIFAL_FUEL_ANP_CODES`, `DIFAL_EXEMPT_ICMS` | the RVs they name (I08-140, I08-141, NA01-20) | an NT rewrites the rule |
| IBS/CBS standard rates by year | `Rates::IBS_CBS` (2027 and 2028 have no CBS rate yet; nothing after 2028) | IT 2025.002 §05 and the laws that set each year's rates | yearly, before the first issue of the year |
| Interstate ICMS rates and the DIFAL partition | `Rates::SOUTH_SOUTHEAST`, `IMPORTED_ORIGINS`, `PARTITION` | Senate Resolutions 22/1989 and 13/2012, EC 87/2015 | a new resolution (rare) |
| NFC-e web services and each state's NFC-e authorizer | `nfce/endpoints.rb` (`AUTHORIZERS`, `PATHS`), `Nfce::States::OWN_AUTHORIZER` | "Relação de Serviços Web" (`dfe-portal.svrs.rs.gov.br/Nfce/Servicos`) | a state moves to or from the SVRS, or an address changes |
| NFC-e QR code and consultation addresses | `Nfce::Endpoints::QR_CODE`, `CONSULT` | Portal Nacional da NFC-e, "URL por UF utilizada QR code" and "... para consulta chave" | a state moves its consultation |
| Lists the NFC-e rules consult | in `nfce/validator.rb`: `CFOPS`, `SALE_CFOPS`, `ST_CFOPS`, `CSTS`, `CSOSNS`, `STATE_CFOPS`, `BARRED`, `BARRED_ITEM` | the RVs of modelo 65 and the NTs that amend them | an NT changes a rule of modelo 65 |
| Web service addresses, each state's authorizer and SVC, and who offers consulta cadastro | `nfe/endpoints.rb` (`AUTHORIZERS`, `PATHS`, `CONTINGENCY`, `REGISTRY_URLS`, `REGISTRY_SVRS`), `States::OWN_AUTHORIZER`, `SVAN` and `SVC_AN`, `nfe/distribution/endpoints.rb` | "Relação de Serviços Web" (`dfe-portal.svrs.rs.gov.br/Nfe/Servicos` and the Portal Nacional) | a state moves to or from a SEFAZ Virtual, or an address changes |
| Status codes the client acts on | `nfe/status_codes.rb` | Anexo I §4.4 and the NTs | an NT adds a `cStat` that changes the flow |
| ICP-Brasil root CAs | `lib/dfe_rb/certs/icp-brasil.pem` (v5, v10, v11, v12; v5 expires 02/03/2029) | `acraiz.icpbrasil.gov.br/credenciadas/RAIZ` | ITI publishes a new root, or one expires |

State tables (internal ICMS and FCP rates, cBenef x CST, MVAs) aren't shipped, so they are the application's to keep current.

After an update: `bundle exec rake`, then the live checks against homologação when a schema, a rule or an address changed.
