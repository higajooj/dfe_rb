> ⚠️ Actively evolving. Breaking changes are the norm!

# dfe_rb

Ruby client for the Brazilian SEFAZ DF-e web services, with an A1 certificate.

- **Emit NF-e** (modelo 55, layout 4.00) in production and homologação: build, validate, sign, authorize, consult, cancel, correct (CC-e) and inutilize. IBS/CBS (Reforma Tributária) included.
- **Distribution** (`NFeDistribuicaoDFe`) and all four **recipient manifestations** through `DfeRb::Nfe::Distribution::Client`: typed metadata, exact decoded XML, cooldown advice and signed events ready to archive.
- **Contingency**: the SEFAZ Virtuais de Contingência (SVC-AN, SVC-RS) and the EPEC.
- **Consulta cadastro**: a taxpayer's state registration, situation and address, from the state itself.

Not covered yet: NFC-e (modelo 65), off-line and paper contingency (`tpEmis` 9, FS-DA), other DF-e (CT-e, MDF-e, NFS-e).

```ruby
gem "dfe_rb", github: "higajooj/dfe_rb", tag: "v0.7.0"
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

  `script/update_tables --cfop <file.xlsx>` regenerates the CFOP table from the `.xlsx` the Portal Nacional da NF-e publishes, and `--tipi <Tipi.xlsx>` regenerates the TIPI from the Receita Federal's.
- **Operation-dependent codes**: a 3-digit CFOP (`"102"`) gets the first digit the operation calls for (`5102`, `6102`, `7102`, or `1`/`2`/`3` on entries). `finNFe` is 5 with a `credit_note_type` (`tpNFCredito`), 6 with a `debit_note_type`, otherwise 1. `tpNF` is 0 (entry) on a credit note or when every item has an entry CFOP (`1102`), otherwise 1. The gem flags a devolução CFOP (`5202`) on a note that isn't a return (rej. 328). Give `purpose :return` yourself, since a complement of a return (`:complementary`) takes the same CFOPs.
- **Billing and payment**: a single payment without amount pays `vNF` (0.00 for tPag 90/91); `fat/vOrig` defaults to `vNF`, `vLiq` to `vOrig - vDesc`, a single installment to `vLiq`, and installments are numbered `001`, `002`...
- **Responsável técnico**: `technical_contact:` on the `Client` (or `Invoice.new`) fills `infRespTec` on every invoice and, with `csrt:`, its `hashCSRT` (NT 2018.005). The CSRT never goes into the XML.

**State law is always yours to give.** The gem derives only what federal law or a national table fixes. It never fills in what each state's ICMS regulation decides: the internal `pICMS` of a product, base reductions (`pRedBC`, `pRedBCST`) and benefit codes (`cBenef`), FCP rates (`pFCP`, `pFCPST`, `pFCPUFDest`), the ST margin (`pMVAST`), the destination's internal rate (`pICMSUFDest`), or the ICMS CST itself. SEFAZ mostly doesn't check these, so a wrong value is usually authorized. The gem ships no state table either (internal and FCP rates, cBenef x CST): those are your application's to keep.

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

The gem takes A1 certificates only, from a `.pfx` (`DfeRb::Certificate.from_pkcs12`), PEM, or OpenSSL objects you already hold (`DfeRb::Certificate.new(certificate:, private_key:, chain: [])`). Files encrypted with RC2-40 (common in ICP-Brasil A1) are opened through the OpenSSL legacy provider, which is loaded only while parsing. A precompiled Ruby (mise, rv...) whose OpenSSL can't find that provider gets it from the system's OpenSSL 3 (`openssl version -m`); set `OPENSSL_MODULES` to point elsewhere.

## Testing

`bundle exec rake` runs the specs (no network) and Standard. Live checks against homologação are opt-in:

```sh
DFE_RB_LIVE=1 DFE_RB_PFX=empresa.pfx DFE_RB_PFX_PASSWORD=... bundle exec rspec spec/live
```

They confirm the SOAP contract and every service with your certificate, including national distribution and a mixed manifestation lot. Distribution checks consume your homologação query quota and can return an existing 656 block; set `DFE_RB_LIVE_LAST_NSU` to your coordinated cursor. Optional `DFE_RB_LIVE_NSU` and `DFE_RB_LIVE_DISTRIBUTION_KEY` control targeted checks. The full lifecycle example (authorize, consult, correct, cancel, inutilize) also needs an issuer registered at the state: see the header of `spec/live/nfe_homologacao_spec.rb`.

## Legislation

Built from MOC 7.0 (Anexo I v7.03) and the NTs up to NT 2026.009, with the layout read from the `PL_010f_v1.04` schema package. Distribution uses `PL_NFeDistDFe_104` (NT 2014.002 v1.40); recipient manifestations follow NT 2020.001 v1.60, the unchanged official manifestation detail schemas, and the generic event schemas from `PL_010d_v1.03` for alphanumeric identities. Contingency follows Anexo III of the MOC and NT 2014.001 v1.41 (EPEC), with each state's SVC taken from the Portal Nacional's "Relação de Serviços Web", which has changed since Anexo III was written; consulta cadastro follows MOC 5.6 and `PL_010d_v1.03`. Where the MOC and later NTs disagree, the NTs and the schema win (synchronous authorization of single-note lots, 7-day late-issue window, 4-digit `cStat`, alphanumeric CNPJ).

## Keeping up with official publications

Everything below is a copy of something the government publishes, so it goes stale. Each change ships in a release of the gem.

Tables regenerated by `script/update_tables` (into `lib/dfe_rb/nfe/data`):

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
| Web service addresses, each state's authorizer and SVC, and who offers consulta cadastro | `nfe/endpoints.rb` (`AUTHORIZERS`, `PATHS`, `CONTINGENCY`, `REGISTRY_URLS`, `REGISTRY_SVRS`), `States::OWN_AUTHORIZER`, `SVAN` and `SVC_AN`, `nfe/distribution/endpoints.rb` | "Relação de Serviços Web" (`dfe-portal.svrs.rs.gov.br/Nfe/Servicos` and the Portal Nacional) | a state moves to or from a SEFAZ Virtual, or an address changes |
| Status codes the client acts on | `nfe/status_codes.rb` | Anexo I §4.4 and the NTs | an NT adds a `cStat` that changes the flow |
| ICP-Brasil root CAs | `lib/dfe_rb/certs/icp-brasil.pem` (v5, v10, v11, v12; v5 expires 02/03/2029) | `acraiz.icpbrasil.gov.br/credenciadas/RAIZ` | ITI publishes a new root, or one expires |

State tables (internal ICMS and FCP rates, cBenef x CST, MVAs) aren't shipped, so they are the application's to keep current.

After an update: `bundle exec rake`, then the live checks against homologação when a schema, a rule or an address changed.
