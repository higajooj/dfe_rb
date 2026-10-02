> ⚠️ Actively evolving. Breaking changes are the norm!

# dfe_rb

Ruby client for the Brazilian SEFAZ DF-e web services, with an A1 certificate.

- **Emit NF-e** (modelo 55, layout 4.00) in production and homologação: build, validate, sign, authorize, consult, cancel, correct (CC-e) and inutilize. IBS/CBS (Reforma Tributária) included.
- **Distribution** (`NFeDistribuicaoDFe`) and all four **recipient manifestations** through `DfeRb::Nfe::Distribution::Client`: typed metadata, exact decoded XML, consumption guidance, and signed events ready to archive.

Not covered yet: NFC-e (modelo 65), contingency (SVC, EPEC, offline), DANFE printing, other DF-e (CT-e, MDF-e, NFS-e).

```ruby
gem "dfe_rb", github: "higajooj/dfe_rb", tag: "v0.4.1"
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

You provide the facts of the operation: parties, items, the bases and rates of each tax (or the tax classification), payments, the number and series. The gem does not choose a tax treatment and does not store numbering.

The gem fills in and derives: `cUF`, `mod`, `tpEmis`, `tpAmb`, `finNFe`, `indPres`, `procEmi`, `verProc`, the issue time (in the issuer's UTC offset), the random `cNF`, the check digit, the `Id`/chave de acesso, `idDest`, `indIEDest` (`"ISENTO"` is understood), `indFinal`, `cEAN`/`cEANTrib` (`SEM GTIN`), `uTrib`/`qTrib`/`vUnTrib`, `vProd`, every total (`ICMSTot`, `IBSCBSTot`, `ISTot`, `vNF`, `vNFTot`), `vItem`, `vTroco`, `modFrete`, plus:

- **Tax values whose result the validation rules fix** (base × rate, ±0.01 tolerance): `vICMS`, `vFCP`, `vICMSOp`/`vICMSDif` (CST 51), `vBCST` by margin (`modBCST` 4) and `vICMSST`, `vFCPST`, `vFCPSTRet`, `vIPI`, `vPIS`/`vCOFINS` (by rate or quantity), DIFAL (`vFCPUFDest`, `vICMSUFDest`, `vICMSUFRemet`), `vIS`, and IBS/CBS: the base (RV UB16-10), `vDif`, `pAliqEfet`, `vIBSUF`, `vIBSMun`, `vIBS`, `vCBS`.
- **Rates fixed by law**: the interstate `pICMS`/`pICMSInter` (4%, 7% or 12% by states and origin), `pICMSInterPart` by year, and the IBS/CBS standard rates of the issue year (IT 2025.002; a rate the law hasn't set yet is left for you to give).
- **Official tables** (shipped in `lib/dfe_rb/nfe/data`, refreshed by `script/update_tables`): the IBS/CBS `CST` and rate reduction (`gRed`) from `class_code` (cClassTrib), and an address's `xMun` from `cMun`, `cMun` from `xMun` + `UF`, or `UF` from `cMun` (IBGE).
- **Operation-dependent codes**: a 3-digit CFOP (`"102"`) gets the first digit the operation calls for (`5102`, `6102`, `7102`, or `1`/`2`/`3` on entries).
- **Billing and payment**: a single payment without amount pays `vNF` (0.00 for tPag 90/91); `fat/vOrig` defaults to `vNF`, `vLiq` to `vOrig - vDesc`, a single installment to `vLiq`, and installments are numbered `001`, `002`...
- **Responsável técnico**: `technical_contact:` on the `Client` (or `Invoice.new`) fills `infRespTec` on every invoice and, with `csrt:`, its `hashCSRT` (NT 2018.005). The CSRT never goes into the XML.

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
```

The XML group comes from the CST/CSOSN. Regime normal (`tax_regime: :normal`) must carry IBS/CBS on every note except returns (RV UB12-10): in homologação since 01/07/2026, and not yet in production (NT 2025.002 v1.51 moved it to a future date). The CST and `cClassTrib` codes come from the Portal Nacional tables (the gem checks their format, not their meaning).

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

Lost answers are handled for you: after a timeout that may have reached SEFAZ, or a duplicate rejection (204/539), the gem asks for the key. If SEFAZ holds this same document it returns its protocol (`result.recovered?`), or `:canceled` if the note was canceled since; if it holds a different one, `Conflict` is raised; if it holds nothing, the original error is re-raised and the *same signed XML* can be sent again. This is why you must store `signed.xml` first and never rebuild a note that may have been sent. A stored note can be handed back as `SignedInvoice.new(xml: File.read(path), key: nil, digest_value: nil)` or as the XML itself; it is checked against the client's environment, certificate and signature before it goes out.

If polling an accepted lot fails, the results come back `pending?` with the lot's `receipt` (notes SEFAZ already reports are recovered by key); `client.resume(receipt, results)` collects the rest.

## After authorization

```ruby
client.consult(key)                                              # => ConsultResult (status, protocol, events)
client.cancel(key, protocol: result.protocol, reason: "Erro na digitação dos dados")   # 110111, up to 24 h
client.correct(key, text: "Corrigir o endereço de entrega", sequence: 1)               # CC-e 110110
client.inutilize(series: 1, from: 10, to: 12, reason: "Numeração pulada por erro")
event.proc_xml                                                   # procEventoNFe to archive, as event.filename ("<chave>_<tpEvento>_<seq>-procEventoNFe.xml")
```

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

This client always uses **Ambiente Nacional**, independently of the issuer's authorizer. Optional `uf: "MS"` sends `cUFAutor`; omitting it leaves that optional field out. Like the emission client, it accepts `transport:`, `endpoints:`, `timeouts:`, `logger:` and `clock:`. Endpoint overrides use `:distribution` and `:manifestation`; `raw(service, xml)` returns the unparsed service answer. Homologação is the default. CNPJ punctuation/case is normalized; numeric and alphanumeric CNPJ and CPF are supported. A company's certificate can query any branch sharing its CNPJ base; an e-CPF can query only its own CPF. Certificate validity and identity are checked before requests.

Every query returns a `DistributionResult`. Its status is `:documents` (138), `:empty` (137), `:blocked` (656), `:unavailable` (108/109), or `:rejected`; `success?` includes both 137 and 138. `distribute!`, `fetch_nsu!`, and `fetch_key!` raise `DfeRb::Nfe::Rejected` or `ConsumptionBlocked` for unsuccessful outcomes and retain the result in `error.result`. Results also expose `query` (`:dist_nsu`, `:cons_nsu`, `:cons_key`), `environment`, `application_version`, `responded_at`, `request_xml`, and `response_xml`.

Documents expose `kind`, `schema`, optional `nsu`, `key` where available, `xml`, and `filename`. The XML is the **exact decompressed content**, including its declaration and whitespace. There are five document types:

| Type | Kind | Metadata |
| --- | --- | --- |
| `InvoiceSummary` | `:invoice_summary` | `issuer_tax_id`, `issuer_name`, `state_registration`, `issued_at`, `direction`, `total`, `digest_value`, `received_at`, `protocol`, `situation_code`, `status` |
| `InvoiceDocument` | `:invoice` | Issuer identity/name, `recipient_tax_id`, issue/receipt times, `total`, `protocol`, `code`, `message` |
| `EventSummary` | `:event_summary` | `type`, `sequence`, `description`, `author_tax_id`, `authority`, `occurred_at`, `registered_at`, `protocol` |
| `EventDocument` | `:event` | Event summary metadata plus `code` and `message` |
| `UnknownDocument` | `:unknown` | Preserved XML and a safe deterministic filename |

These classes live under `DfeRb::Nfe::Distribution`. Monetary totals are `BigDecimal`, timestamps are `Time` with their source offset, and protocol numbers remain strings. Historic date-only issue dates become midnight UTC. The invoice summary's `status` is `:authorized`, `:denied`, `:canceled`, or `:unknown`; a downloaded full invoice's authorization protocol does not by itself establish its current situation—keep subsequent events too. `summary?`, `invoice?`, and `event?` distinguish documents. Full invoice contents remain available through XML rather than a second invoice object model.

The actual XML root determines the document type. Other valid XML is preserved as `UnknownDocument`, and distributed events are not restricted to the four manifestation types. The gem never opens a schema named in a response. Invalid XML, Base64, Gzip/CRC, conflicting protocol identities, and oversized decompression raise `Distribution::InvalidResponse < DfeRb::TransportError`, with `response_xml`, `schema`, and `nsu` where available. A bad document fails the entire batch. The decompressed limit is 10 MiB per document; adjust `max_document_bytes:` when necessary.

### Consumption rules and cursors

The gem performs **one request per call**. It does not sleep, paginate, retry, store cursors, enforce in-memory quotas, or coordinate processes. Your application must share a single ordered `ultNSU` cursor for each interested party/environment across every consumer and preserve SEFAZ's returned `last_nsu` rather than deriving it from document NSUs. Returned document NSUs and response cursors can be absent; targeted queries never advance your distribution cursor.

After a sequential 137, or a successful batch reaching `max_nsu`, wait at least one hour. Any 656 also requires a one-hour wait; another request before the hour expires restarts the block. `retry_at` is computed conservatively from local response receipt. Targeted queries have a limit of 20 queries per hour; coordinate their use across consumers. An empty targeted query does not imply sequential exhaustion, so it has no automatic cooldown advice unless it returns 656.

Documents are available for up to 90 days after reception by Ambiente Nacional. New consumers start generating NSUs on their first sequential query; there is no retroactive NSU generation. After more than 60 days without use, generation pauses and resumes on the next sequential query, also without backfilling the gap. A zero cursor does not guarantee recovery of every invoice from the last 90 days. Issuers retrieve distributed documents of interest, such as recipient events, rather than their own issued invoices.

### Explicit recipient manifestations

```ruby
key = received_key # select a received NF-e from your application

distribution.manifest(key, type: :awareness) # 210210: Ciência da Operação
# Choose the appropriate conclusive statement for the actual operation:
distribution.manifest(key, type: :confirmation)      # 210200
distribution.manifest(key, type: :unknown_operation) # 210220
distribution.manifest(key, type: :not_performed, reason: "Mercadoria recusada pelo destinatario") # 210240
```

These are alternative statements of the recipient's knowledge and participation; select the one that describes the operation. The gem never sends one while querying or decoding documents. Awareness is optional and is not conclusive. It, confirmation, and operation-not-performed can make full XML available to the recipient; unknown-operation does not unlock it. The intended workflow is: retrieve summary, explicitly submit the appropriate manifestation, then retrieve the newly available full XML with a later distribution or targeted query. Availability is asynchronous and not guaranteed by the event response alone.

Each conclusive type permits sequences 1 and 2; awareness permits only 1. Set `sequence: 2` explicitly for a second occurrence; the gem never increments it after a rejection or duplicate. The current NT specifies awareness within 10 days of authorization and conclusive manifestations within 90 days, with the applicable rectification rules. The application must decide which manifestation is appropriate and track its legal deadlines/history; the gem cannot infer that from an access key.

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

A key-based call builds and submits in one step. Arrays return arrays in input order, including for one element. Prepared events permit mixed types; a scalar returns one `ManifestationResult`. Stored events are revalidated for their author, environment, official details, signing certificate identity, signature, and event ID. A renewed certificate for the same company can transmit an earlier event; the embedded signing certificate must have been valid at the event time. The exact signed bytes are kept. `reason:` is required only for `:not_performed`, with 15–255 characters. Duplicate event identities within a batch are rejected locally, and prepared events cannot have their type/details overridden.

Manifestation results distinguish `:registered` (135, `linked?`), `:registered_unlinked` (136), `:duplicate` (573), and `:rejected`. `registered?` includes 135/136. They expose `key`, official event `type`, `sequence`, `code`, `message`, `protocol`, `registered_at`, `event_xml`, `return_xml`, `request_xml`, and `response_xml`. Only registered answers produce `proc_xml`. `manifest!` raises for unsuccessful events, including duplicates; it does not turn a duplicate into a registration or invent its protocol. Malformed, missing, or conflicting event answers raise `InvalidResponse`.

A transport failure preserves `maybe_processed?`. A lost manifestation answer may already have registered the event: keep the signed XML and reconcile the outcome before resubmission. There is no automatic retry or recovery lookup, and distribution queries after a lost answer may still have affected SEFAZ's consumption controls.

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

They confirm the SOAP contract and every service with your certificate, including national distribution and a mixed manifestation lot. Distribution checks consume your homologação query quota and can return an existing 656 block; set `DFE_RB_LIVE_LAST_NSU` to your coordinated cursor. Optional `DFE_RB_LIVE_NSU` and `DFE_RB_LIVE_DISTRIBUTION_KEY` control targeted checks. The full lifecycle example (authorize, consult, correct, cancel, inutilize) also needs an issuer registered at the state: see the header of `spec/live/nfe_homologacao_spec.rb`.

## Legislation

Built from MOC 7.0 (Anexo I v7.03) and the NTs up to NT 2026.009, with the layout read from the `PL_010f_v1.04` schema package. Distribution uses `PL_NFeDistDFe_104` (NT 2014.002 v1.40); recipient manifestations follow NT 2020.001 v1.60, the unchanged official manifestation detail schemas, and the generic event schemas from `PL_010d_v1.03` for alphanumeric identities. Where the MOC and later NTs disagree, the NTs and the schema win (synchronous authorization of single-note lots, 7-day late-issue window, 4-digit `cStat`, alphanumeric CNPJ).
