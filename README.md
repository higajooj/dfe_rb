> ⚠️ Actively evolving. Breaking changes are the norm!

# dfe_rb

Ruby client for the Brazilian SEFAZ DF-e web services, with an A1 certificate.

- **Emit NF-e** (modelo 55, layout 4.00) in production and homologação: build, validate, sign, authorize, consult, cancel, correct (CC-e) and inutilize. IBS/CBS (Reforma Tributária) included.
- **Distribution** (`NFeDistribuicaoDFe`) and all four **recipient manifestations** through `DfeRb::Nfe::Distribution::Client`: typed metadata, exact decoded XML, cooldown advice and signed events ready to archive.
- **Contingency**: the SEFAZ Virtuais de Contingência (SVC-AN, SVC-RS) and the EPEC.
- **Consulta cadastro**: a taxpayer's state registration, situation and address, from the state itself.
- **Emit NFC-e** (modelo 65, layout 4.00) through `DfeRb::Nfce::Client`: the same builder, with the QR code version 3 (no CSC), its off-line contingency, the cancellation by substitution and the rules of modelo 65. See [NFC-e](#nfc-e).
- **Print an NF-e as the DANFE Simplificado Tipo 2** (`tpImp` 6), for a counter sale an NFC-e would otherwise cover: the NFC-e's QR code, on-line or off-line, and its rules. See [DANFE Simplificado Tipo 2](#danfe-simplificado-tipo-2).
- **Emit CT-e** (modelo 57, layout 4.00), all six modals: build, validate, sign, authorize synchronously, consult, cancel, correct (CC-e), record delivery receipts and failures, register service disagreements and payment links, SVC and off-line contingency, IBS/CBS (Reforma Tributária), and its distribution service. See [CT-e](#ct-e).
- **Emit MDF-e** (modelo 58, layout 3.00), all four modals: build, validate, sign, authorize, consult, cancel, close, add drivers and documents, off-line contingency, and its distribution service. See [MDF-e](#mdf-e).
- **Issue NFS-e** of the Padrão Nacional through the Sistema Nacional NFS-e (the Sefin Nacional's API, JSON over mutual TLS): build the DPS in the production layout or NT 009's (IBS/CBS included), validate, sign, issue, look up, cancel, confirm or reject as a party, and the ADN's distribution and municipal parameters. See [NFS-e](#nfs-e).
- **Write the EFD ICMS/IPI** (SPED Fiscal) of a period: its registers, the blocks' openings and closings and Block 9, an NF-e's or NFC-e's C100, C101, C170 and C190 from its XML, and the apurações of Block E. See [EFD ICMS/IPI](#efd-icmsipi).
- **Write the EFD-Contribuições** (PIS/Pasep and COFINS) of a period up to December 2026: its registers, an NF-e's C100 and C170 or an NFC-e's C175 with their PIS and COFINS, the apuração of Block M and the credits carried in Block 1. See [EFD-Contribuições](#efd-contribuições).

Not covered yet: the NFC-e's EPEC (NT 2014.003) and QR code version 2 (with CSC), paper contingency of the NF-e (FS-IA, FS-DA), CT-e OS (modelo 67), CT-e Simplificado and GTV-e (modelo 64), the DACTE, DAMDFE and DANFSe, municipal NFS-e systems outside the Sistema Nacional, and the MDF-e's ANTT payment events.

```ruby
gem "dfe_rb", github: "higajooj/dfe_rb", tag: "v0.23.0"
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
- **Tax values whose result the validation rules fix** (base × rate, ±0.01 tolerance): `vICMS`, `vFCP`, `vICMSOp`/`vICMSDif` (CST 51), `vICMSST` from `vBCST`, `vFCPST`, `vFCPSTRet`, `vIPI`, `vPIS`/`vCOFINS` (by rate or quantity), DIFAL (`vFCPUFDest`, `vICMSUFDest`, `vICMSUFRemet`), `vIS`, and IBS/CBS: the base (as UB16-10 gave it, removed by NT 2026.008), `vDif`, `pAliqEfet`, `vIBSUF`, `vIBSMun`, `vIBS`, `vCBS`.
- **Rates fixed by law**, on a normal operation (`finNFe` 1). That covers the interstate `pICMS`/`pICMSInter` (4%, 7% or 12% by states and origin), `pICMSInterPart` by year, the IBS/CBS standard rates of the issue year (IT 2025.002; a rate the law hasn't set yet is yours to give, and the note is refused without it: see [2027](#2027)), and `pIPI` from the TIPI line of the item's `NCM` and `EXTIPI` when you give `i.ipi` a base without a rate (an NT line and a per-unit IPI get none; zero from 2027 but on a product of the Zona Franca de Manaus). A return, complement or adjustment carries the rates of the operation it refers to, so you give them. So does an item with a retorno or anulação CFOP (`6916`, `6206`...), for the interstate ICMS rates.
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
DfeRb::Nfe::Rates.ibs_cbs(2027)                                                # => {uf: 0.05, municipal: 0.05, cbs: nil} until the reference rate applies
DfeRb::Nfe::Rates.pis_cofins_charged?(Date.new(2027, 1, 1))                    # => false
DfeRb::Nfe::Rates.ipi_applies?(2027, zfm_product: false)                       # => false
DfeRb::Nfe::Apportion.call("10.00", %w[100 200])                               # => [3.33, 6.67]
```

The XML group comes from the CST/CSOSN. A regime normal issuer (`tax_regime: :normal`) must put IBS/CBS on every note except a return or a complement that references a note issued before 2027 (RV UB12-10, NT 2025.002 v1.53; the date is the AAMM of the referenced key, see [What a return references](#what-a-return-references)). Homologação has rejected a note without it since 01/07/2026. In production the law has required it since 01/01/2026, but the rejection has no date yet. The Simples Nacional fills it from 2027 (LC 214/2025, art. 348) under NT 2026.005, which gives no rule for leaving it out, so nothing is asked of it; a MEI sends none (see [the Simples Nacional](#the-simples-nacional-nt-2026005)). The CST and `cClassTrib` codes come from the tables of IT 2025.002, which the gem ships (see [Official tables](#official-tables)): it checks the `cClassTrib` exists and is in force on the issue date, belongs to its CST and may go on the note's model, and checks the operation's presumed credit (`gCredPresOper`) against the cCredPres table.

`vNF` follows RV W16-10: exemptions are deducted per item (only where `exemption_deducted: 1`), retained monophase ICMS (`ICMS15`) is added, PIS-ST/COFINS-ST are added when the item asks for it, and ICMS-ST stays out of a direct sale of new vehicles. `payment :deferred_payment, "0.00"` is pagamento posterior (tPag 91).

### Linking a payment transaction (NT 2026.006)

Production moved from 16/11 to 14/12/2026 (the Portal's aviso of 13/11/2026). For the split payment (expected from 2027; nothing asks for it in production in 2026) a note lists the payment transactions started before it, a boleto or a dynamic Pix, even unpaid (group YC, `gPgtoVinc`):

```ruby
nfe.payment_link :bank_slip, transaction_id: "BOLETO-0001", receiver_cnpj: "11.222.333/0001-81", psp_cnpj_base: "00000000"
nfe.payment_link :pix, transaction_id: "E0003816620261214...", receiver_cnpj: "11222333000181", psp_cnpj_base: "00038166"
```

`tpMeioPgto` takes the codes of IT 2026.001 (`DfeRb::Nfe::Tables.payment_link_methods`): 15 `:bank_slip`, 17 `:pix`, 18 `:bank_transfer`, 20 `:static_pix`, 23 `:automatic_pix`, 24 `:book_transfer`. `nPag` is numbered for you. The validator checks the code (YC05-10, rej. 1273), the receiver's CNPJ (YC06-10, rej. 1274) and a repeated `nPag` or `idTransacao` (YC03-10, YC04-20, rej. 215), from 14/12/2026 in production and 26/10/2026 in homologação, by `dhEmi`. This group doesn't replace `pag` and `infIntermed`, which state law still asks.

To link a transaction to a note already authorized (a Pix QR code made after it, or a key mistyped in the payment), send the event 110300, one transaction each, then take it back with 110001 if it was wrong:

```ruby
client.link_payment(key, protocol: "135260000000123", transaction_id: "E0003816620261214...", method: :pix,
  receiver_cnpj: "11222333000181", psp_cnpj_base: "00038166")            # sequence: 2 for the next one
client.cancel_event(key, type: "110300", protocol: "135260000000999", sequence: 1)   # the event's own protocol and sequence
```

Both refuse what the rules refuse before sending (P26-10, P27-10) and check the event's detail against `e110300_v1.00.xsd` and `e110001_v1.00.xsd` (`DfeRb::Nfe::Events.detail_issues`). The package of schemas has no `envEventoNFe` schema: the envelope goes by the generic one. A live check in homologação, once the authorizers take the layout after 14/12/2026, is still to be made.

### The Simples Nacional (NT 2026.005)

From 14/12/2026 in production (the Portal's aviso of 13/11/2026 moved it from 16/11) the Simples Nacional's IBS and CBS have their own fields. The issuer's regime fixes which go on the note (§2.3 of the NT):

| Issuer | `ibs_cbs_regime:` (`tpRegimeIBSCBS`) | item's IBS/CBS | `simples_ibs:` / `simples_cbs:` (`gTribSN`) |
|---|---|---|---|
| CRT 1 or 2 (`:simples`, `:simples_excess`), regular regime | 1 | `ibs_uf`, `ibs_municipal`, `cbs` | none |
| CRT 1, no regular regime | none | none | both |
| CRT 2, no regular regime | none | `ibs_uf`, `ibs_municipal`, `cbs` with the CBS at zero (the gem fills it) | `simples_cbs` only |
| CRT 3 with the option for the Simples pending, no regular regime for CRT 1 | 2 | `ibs_uf`, `ibs_municipal`, `cbs` | both |
| the same, for CRT 2 | 3 | the same | `simples_cbs` only |
| the same, with the regular regime | 4 | the same | none |
| MEI (`:mei`) | none | no IBSCBS at all | none |

```ruby
# CRT 1 without the regular regime: no tpRegimeIBSCBS, no gIBSCBS, both groups of gTribSN
nfe.issuer tax_id: "...", tax_regime: :simples, ...
nfe.item do |i|
  i.simples_activity "01"                                                  # cAtivSN: 01, 02, 03, 04 or 90
  i.ibs_cbs class_code: "000001", simples_ibs: {rate: "1.00", amount: "1.00"}, simples_cbs: {rate: "0.50", amount: "0.50"}
end

# CRT 1 with the regular regime: tpRegimeIBSCBS 1 and the regular groups, no gTribSN
nfe.issuer tax_id: "...", tax_regime: :simples, ibs_cbs_regime: 1, ...
nfe.item { |i| i.simples_activity "01"; i.ibs_cbs class_code: "000001" }
```

Every item of an optante, or of a regime normal issuer with the option pending, gives `simples_activity`. The effective rates and amounts of `gTribSN` (`pIBSSN`, `vIBSSN`, `pCBSSN`, `vCBSSN`) are yours, since the NT gives no base to work them out from: the gem totals them in `IBSCBSTot/gTribSN` (W59h to W59j), which the validator holds to the sum of the items (rej. 1275, 1276, 1277, 1284). It flags a MEI's IBSCBS and `tpRegimeIBSCBS`, a pair of CRT and `tpRegimeIBSCBS` the NT doesn't name, `cAtivSN` from an issuer who doesn't give it, and a group the table says "não informar". The table has no rejection codes, so what it says to "informar" is left to SEFAZ, and so is a return or refusal, whose IBSCBS mirrors the supply note and may carry the regime the supply had (§2.4). The rules apply from 14/12/2026 in production and 26/10/2026 in homologação, by `dhEmi`.

Event 412140, "Tributação do Simples Nacional", is generated by the Administração Tributária, never sent by the issuer. `DfeRb::Nfe::Events.detail_issues("412140", detail_xml)` checks one received from the distribution against its schema (`e412140_v1.00.xsd`).

### Net value, and the ICMS of an advance payment (NT 2026.008 v1.01)

Production moved from 16/11 to 14/12/2026 (Portal's aviso of 13/11/2026); before that SEFAZ's schema takes none of these fields. Give an item its net value, the value without any tax, with `net_unit_price:` (`vUnComLiq`) or `net_amount:` (`vProdLiq`): the gem works out the other (`vProdLiq` = `vUnComLiq` x `qCom`, RV I11c-20, within a cent) and writes the note's `vProdLiqTot` (W01a) as the sum. It makes up nothing for an item that gives neither, since which taxes a price carries isn't its to know (I11c-10, `vProdLiq` required, is "implementação futura" and not checked). The validator flags a `vProdLiq` that isn't the price x quantity on a normal note (I11c-20, rej. 1279) and a total that is missing or isn't the sum (W01a-10, W01a-20, rej. 1282, 1283), from 14/12/2026 in production and 26/10/2026 in homologação.

```ruby
nfe.item do |i|
  i.unit_price "10.00"
  i.net_unit_price "8.50"   # vProdLiq 25.50 for 3 units, vProdLiqTot on the note
end
```

An NF-e of a debit note of type 06 (`debit_note_type "06"`) or of `tpOperGov` 4 carries, on each item, the ICMS expected at the supply: `i.icms forecast_amount: "12.00"` (`ICMS/ICMSPrevistoPagtoAntecip/vICMSPrevisto`, NB01; `"0.00"` where none falls). No other note carries it, an NFC-e least of all (NB01-10, NB01-20, rej. 1280), and its absence is flagged from 01/03/2027 in production and 01/02/2027 in homologação (NB01-30, rej. 1281). B25-80 (rej. 1001) bars ICMS, ISSQN, IPI, II, PIS, COFINS, ICMSUFDest and `impostoDevol` from a debit or credit note and from the receipt of a payment (`tpOperGov` 2); a debit note of type 06 may carry the IPI, the NB01 group and, in 2026, PIS and COFINS, and the credit notes 03, 04 and 06 and the debit note 07 are spared.

**What `vProd` carries from 2027.** NT 2026.008 v1.01 contradicts itself. Its introduction says `vProd` leaves IBS, CBS and IS out, and `vItem` has every tax. The field table (I11: "a partir de 2027, os valores de IBS, CBS e IS compõem o Valor Total Bruto, exceto nas notas de importação") and the rules VB01-10 and VB01-20 ("(+) vProd (contém vIBS, vCBS e vIS)") say `vProd` contains them, and no later NT settles it. The gem follows the table and the rules: `vProd` is the gross value you give, and it never builds it from the taxes. `vItem` is the sum the rules list, which still names "(+) vIBS (+) vCBS (+) vIS" and spares 2025 and 2026 (exceção 1), so that is what the gem fills and checks; it skips the check on an import (CFOP 3xxx, exceção 2). The reading lives in `Totals::VITEM_ADDS_IBS_CBS_IS` and `Totals::IBS_CBS_IN_TOTAL_SINCE`, for a later NT to change. SEFAZ doesn't enforce VB01-10 and VB01-20 yet ("implementação futura"). UB16-10 (rej. 1104, the IBS/CBS base) is gone from the NT, so the base the gem fills when you give none is a default, no longer a rule.

### 2027

On 1 January 2027 the CBS starts being charged at its reference rate, PIS/Pasep and COFINS end, and the IPI goes to zero on almost every product (EC 132/2023, ADCT arts. 126 and 127; LC 214/2025). The gem goes by the issue year of `dhEmi`, in its own offset: `2026-12-31T23:30:00-04:00` is still 2026.

| | Up to 31/12/2026 | From 01/01/2027 |
|---|---|---|
| CBS (`pCBS`) | 0.9% | the reference rate less 0.1 point (LC 214, art. 347), filled once `Rates::CBS_REFERENCE` has it |
| IBS (`pIBSUF`, `pIBSMun`) | 0.1% and 0 | 0.05% and 0.05% (art. 344), in 2027 and 2028 |
| IBS, CBS and IS in `vItem` | no | yes (RV VB01-10; see [what `vProd` carries](#net-value-and-the-icms-of-an-advance-payment-nt-2026008-v101)) |
| PIS and COFINS | charged | not charged; the groups stay mandatory (RV Q01-20, S01-20) |
| IPI from the TIPI | the TIPI rate | zero, unless the item says `zfm_product: true` |

What callers pass on a normal note (`finNFe` 1) dated 2027:

- **The CBS rate, until the gem has it.** The Senate fixes the reference rate by 31 October of the year before (LC 214, art. 349, § 1º), but for 2027 it has until 15/12/2026 (art. 353, § 2º gives the first cycle 45 more days). The TCU calculated 11.3% (28/10/2026), which applies while the Senate hasn't fixed a rate past 22/12/2026 (art. 349, § 2º). Until a release of the gem fills `Rates::CBS_REFERENCE`, give `cbs: {rate: ...}` on each item taxed in `gIBSCBS`, or the note is refused: `issues` names the item ("the CBS reference rate for 2027 isn't published yet (alíquota de referência da CBS para 2027 não publicada): give pCBS"), `to_xml` raises `ValidationError`, and `Calculator.call` raises `DfeRb::Nfe::RateNotPublished`. Nothing is asked of a classification taxed in `gTribRegular` (zero rates) or a CBS with `gALCZFMCBS` (zero, UB56-20). On a return, complement or adjustment the gem fills no rate, so you give them all; the validator still holds a complement or adjustment to the issue year's rates (UB18-10 and UB37-10 don't spare them), so a 2027 complement of a 2026 sale carries the IBS at 0.05% + 0.05%, not 0.1% + 0. After 2028 every rate is yours to give.
- **PIS and COFINS with a CST that charges nothing.** No NT says which one yet, nor drops the groups. The gem flags any rate or amount of PIS, COFINS or their ST on a normal note dated 2027 ("PIS/Pasep and COFINS are not charged on a note issued from 2027"). A return or complement of a 2026 sale may carry them.
- **`zfm_product: true` on the IPI of a product whose IPI goes on**: one with incentivized industrialization in the Zona Franca de Manaus, unless LC 214, art. 454 zeroes it too (a TIPI rate below 6.5% on 31/12/2023; ICT goods excepted). The Union is to publish the list (§ 3º). `i.ipi cst: "50", base: "100.00", zfm_product: true` keeps the TIPI rate; without the flag the gem fills `pIPI` 0. A rate you give is kept.

The validator also checks every note's IBS/CBS rates against the issue year (UB18-10, UB37-10, UB56-10, UB56-20, rej. 1026, 1036, 1037), so a 2026 rate on a 2027 note is flagged. It leaves out a return, the credit notes of a refusal or a reduction (`tpNFCredito` 03, 04, 06), a government purchase, and a CBS of zero in 2026, whose conditions SEFAZ checks.

Still waiting on publications:

- the 2027 reference rate, the Senate's (due 15/12/2026) or else the TCU's 11.3% (11.2% charged), which goes into `Rates::CBS_REFERENCE` in a new release;
- an NT on the PIS/COFINS groups of 2027 notes (NT 2025.002 v1.53 still requires them) and a rule that makes the IBS/CBS group mandatory for the Simples Nacional (RV UB12-10 is for the regime normal; NT 2026.005 says how to fill it, not that it must be);
- the Union's list of the products whose IPI goes to zero (LC 214, art. 454, § 3º), or a new TIPI;
- the Imposto Seletivo rates of MP 1.399/2026, in force from 02/02/2027, which the gem doesn't fill (`i.selective_tax` takes them).

## Other ways to describe an invoice

```ruby
client.build_invoice(number: 1, issuer: {...}, items: [{code: "1", description: "Widget", ...}])   # hash
i.c_prod "SKU-1"; i.xProd "Widget"   # inside an item, every field also answers to its official tag: c_prod, "cProd", x_prod...
client.sign(File.read("nfe.xml"))   # raw <NFe> XML from another system: schema + business rules, signed, sent as is
```

Unknown names fail with a suggestion (`nature_of_operacion` → did you mean `nature_of_operation`?), and symbols map to codes (`tax_regime: :normal`, `payment :pix, ...`, `presence: :internet`).

## Several notes, results and errors

```ruby
results = notes.map { |signed| client.authorize(signed) }   # several notes: one request each, answered at once
client.authorize(signed).status                    # :authorized, :authorized_late, :authorized_with_alert, :denied, :rejected, :pending, :canceled
client.authorize!(signed)                          # raises DfeRb::Nfe::Rejected / Denied / ConsumptionBlocked instead
```

**Send several notes one at a time.** SEFAZ ends the asynchronous authorization lot (RV GAP03a-6, NT 2023.002 v1.02): a request with `indSinc` 0 is rejected with 129 from 01/02/2027 in homologação and 05/04/2027 in production, and the NFC-e has taken one note per request since 2023. `authorize` with an Array of two or more notes still sends the lot until then, warns once (see [Deprecations](#deprecations)) and, from those days, raises `DfeRb::ValidationError` naming RV GAP03a-6 and rej. 129 before anything is sent. It decides by the clock of the request and by the `dhEmi` of the notes, whichever is later. A synchronous request answers with the protocol at once, so there is no receipt to poll. Sign and store every note first, then send them, each in its own call:

```ruby
signed = invoices.map { |invoice| client.sign(invoice) }   # store each signed.xml before any is sent
results = signed.map do |note|
  client.authorize(note)                                   # one note, indSinc 1, the result in the answer
rescue DfeRb::TransportError => e
  e                                                        # this note's answer was lost; the others still go
end
```

Each call recovers its own lost answer or duplicate by key (below), so one failure doesn't stop the rest, and a note that came back as a `TransportError` is sent again later, as the same signed XML.

A rejection is a *result* (SEFAZ answered "no"); exceptions are for problems: `DfeRb::ValidationError` (`#issues` lists everything wrong locally, nothing was sent), `DfeRb::TransportError` (`#maybe_processed?` tells whether SEFAZ may have acted, `#http_status` the status of an answer that wasn't a SOAP one, `#certificate_refused?` a 403, SEFAZ refusing the certificate at the TLS layer), `DfeRb::CertificateError`, `DfeRb::Nfe::Conflict`.

The gem handles lost answers. After a timeout that may have reached SEFAZ, or a duplicate rejection (204/539), it asks for the key. If SEFAZ holds this same document, the gem returns its protocol (`result.recovered?`), or `:canceled` if the note was canceled since. If SEFAZ holds a different document, it raises `Conflict`. If SEFAZ holds nothing, it re-raises the original error, and the *same signed XML* can be sent again. This is why you must store `signed.xml` first and never rebuild a note that may have been sent. You can hand a stored note back as `SignedInvoice.new(xml: File.read(path), key: nil, digest_value: nil)` or as the XML itself. The gem checks it against the client's environment, certificate and signature before it goes out.

A lot accepted before the day SEFAZ ends it is polled until processed. If polling fails, the results come back `pending?` with the lot's `receipt` (notes SEFAZ already reports are recovered by key), and `client.resume(receipt, results)` collects the rest. That receipt query is deprecated with the lot: it is for lots accepted before the day above, and nothing issues a receipt after it.

## After authorization

```ruby
client.consult(key)                                              # => ConsultResult (status, protocol, events)
client.cancel(key, protocol: result.protocol, reason: "Erro na digitação dos dados")   # 110111, up to 24 h
client.correct(key, text: "Corrigir o endereço de entrega", sequence: 1)               # CC-e 110110
client.inutilize(series: 1, from: 10, to: 12, reason: "Numeração pulada por erro")      # not in AC, BA or SP: see below
event.proc_xml                                                   # procEventoNFe to archive, as event.filename ("<chave>_<tpEvento>_<seq>-procEventoNFe.xml")
```

**No inutilização in AC, BA and SP.** Since 11/11/2026, in homologação and in production, their web service doesn't exist (Ajustes SINIEF 38/2026 and 40/2026; RV I01a, NT 2023.002 v1.02): SEFAZ answers 998 "Serviço Desativado" or HTTP 404. `inutilize` for an issuer of those states raises `DfeRb::Nfe::Unsupported` before sending anything, naming the Ajustes, and it raises the same when any state answers 998 or 404. A number skipped there is simply left unused: SEFAZ doesn't check the database of inutilized numbers for them either (RV 3B08-100). Every other state keeps the service, and `DfeRb::Nfe::Retirements.inutilization_off?(uf, Time.now)` tells which.

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

A note that was sent to the state before the outage and never answered must not be reissued under the same number (Anexo III 2.1.3.5): give the SVC note another number and, when the state is back, consult the old key, then cancel it if it was authorized or inutilize its number if not (not in AC, BA and SP, which have no inutilização since 11/11/2026: leave it unused).

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

An NF-e printed as the DANFE Simplificado Tipo 2 has a third way out, the NFC-e's: issue it off-line and send it later (see [DANFE Simplificado Tipo 2](#danfe-simplificado-tipo-2)).

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

Every query returns a `DistributionResult`. Its status is `:documents` (138), `:empty` (137), `:blocked` (656), `:unavailable` (108/109), `:certificate` (the certificate refused: 280 to 287, or 593 and 472 for a holder other than the one asked about), or `:rejected`; `DfeRb::Distribution.status(code)` gives the same for a cStat kept on its own; `success?` is true for both 137 and 138. `distribute!`, `fetch_nsu!`, and `fetch_key!` raise `DfeRb::Nfe::Rejected` or `ConsumptionBlocked` for unsuccessful outcomes and keep the result in `error.result`. Results also expose `query` (`:dist_nsu`, `:cons_nsu`, `:cons_key`), `environment`, `application_version`, `responded_at`, `request_xml`, and `response_xml`.

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
- **QR code version 3** (NT 2025.001): `infNFeSupl` is built for you, with the state's QR code and consultation addresses from the Portal Nacional da NFC-e. A note issued on-line needs no CSC; one issued off-line (`tpEmis` 9) carries its signature as raw Base64 (`+`, `/`, `=`), as NT 2026.003 §4.3.2 prints it, and `QrCode.parse` also reads one a URL encoder touched. Override an address with `endpoints: {qr_code: "...", consult_url: "..."}`.
- **Rules of modelo 65**, checked before sending: the CFOPs an NFC-e takes and the CST or CSOSN each goes with (with the states' own exceptions), the groups it can't carry (IPI, DIFAL, billing, vehicles, references, a pickup place...), home delivery, the consumer's identification above R$ 10.000,00, the payment methods it can't take and the card group of card and PIX payments (391), and the QR code's address, parameters and off-line signature. Rules each state sets (its total cap, the consumer's name and address above R$ 10.000,00, the CSOSNs it bars, home delivery, the NCMs it refuses) stay with SEFAZ.
- **5 minutes to reach SEFAZ**: a note issued on-line is rejected when it arrives more than 5 minutes after its `dhEmi` (RV B09-40, rej. 704). Since sending a note again may be a retry after a lost answer, `authorize` first looks up the key of a note that late: when SEFAZ holds it, that result comes back; when it holds nothing, `ValidationError` says so before anything is sent, so build the note again or issue it off-line.
- **One note per request**, synchronous (RV GAP03a-4, rej. 126; RV GAP03a-6, rej. 129): `authorize` refuses a lot of more. A lost answer or a duplicate is resolved by key, as for the NF-e.
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

A note sent and never answered that SEFAZ doesn't hold is inutilized instead (`client.inutilize(series: 1, from: 20, reason: "...")`, of modelo 65), except in AC, BA and SP, whose inutilização is off since 11/11/2026 (see [After authorization](#after-authorization)).

## DANFE Simplificado Tipo 2

A retailer may issue an NF-e (modelo 55) for a sale an NFC-e would otherwise cover, such as a building-supply store selling at the counter to a contractor with a CNPJ, and print it on the till's roll as the DANFE Simplificado Tipo 2 (Ajuste SINIEF 13/26, NT 2026.002). It is the NF-e's client and builder, with one more line:

```ruby
client = DfeRb::Nfe::Client.new(certificate: certificate, uf: "MS")

invoice = client.build_invoice do |nfe|
  nfe.print_format :simplified_type_2    # tpImp 6
  nfe.series 1
  nfe.number 77
  nfe.nature_of_operation "Venda no balcao"
  nfe.issuer tax_id: "24.647.331/0001-86", name: "LOJA LTDA", state_registration: "282567143", tax_regime: :simples,
    address: {street: "Rua A", number: "100", district: "Centro", city_code: "5002704", zip: "79002000"}
  nfe.recipient cnpj: "11222333000181", name: "CONSTRUTORA", state_registration: "283184527",
    address: {street: "Rua B", number: "1", district: "Centro", city_code: "5002704", zip: "79002000"}
  nfe.item { |i| ...; i.cfop "5102"; i.icms csosn: "102", origin: :domestic }
  nfe.payment :money
end

invoice.qr_code                     # what the DANFE's QR code holds: the NFC-e's version 3
signed = client.sign(invoice)       # infNFeSupl goes ahead of the signature
result = client.authorize(signed)
result.qr_code                      # and result.consult_url, the address it prints for the key
```

- **QR code**: the NFC-e's version 3 at the NFC-e's addresses of the issuer's state (RV ZX02-20, NT 2026.003), built into `infNFeSupl` for you. A QR code of another version is refused (ZX02-220, rej. 672). `endpoints: {qr_code:, consult_url:}` on the client overrides the addresses.
- **Defaults**: the sale is to a final consumer (`indFinal` 1, RV B25a-10), even one with an IE. In homologação the first item's description becomes the text RV I04-10 requires (373).
- **Rules**: the ones NT 2026.002 gives "NFC-e or NF-e with DANFE Simplificado Tipo 2". That means an internal exit (706, 707) of a normal note (715) in person or delivered (717); the NFC-e's CFOPs (725), CSTs (766) and CSOSNs (383), each CFOP with its CST or CSOSN (382, 386); no references, billing, IPI, DIFAL, vehicles, pickup place... (708, 760, 742, 807, 736, 669); freight only on a home delivery (753); the QR code's parameters; and the 5 minutes between `dhEmi` and SEFAZ (704), which `authorize` handles as for the NFC-e. The NF-e's own rules still hold: the recipient is named and located (719), and the payments are the NF-e's.
- **Off-line contingency**: `nfe.contingency :offline, since:, reason:` issues it with `tpEmis` 9, the only NF-e that may (RV B22-10, rej. 711), and a QR code signed with the client's certificate. Print the DANFE in two copies and keep one at the store until the note is authorized (Ajuste SINIEF 14/26). The SVC is out: the schema's QR code takes no SVC key.

An NF-e can't reference this note's NFC-e cousins either. From 14/12/2026 in production (01/09/2026 in homologação), an exit note other than a complement or a return can't reference an NFC-e or a CF-e SAT (RV BA02-35, rej. 679), nor can its items, unless the note is a debit note of unprocessed notes or of fines and interest, `tpNFDebito` 03 or 04 (VC02-40, 679), and a note for a sale a cupom fiscal covered (CFOP 5929, 6929) can't reference an NFC-e (I08-180, rej. 375). Since 05/10/2026 no NF-e may reference a paper note (BA03-10), a rural producer's paper note (BA10-10) or a cupom fiscal (BA20-30).

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

## CT-e

```ruby
client = DfeRb::Cte::Client.new(certificate: certificate, uf: "SP")   # homologação unless told otherwise

waybill = client.build_waybill do |cte|
  cte.number 42
  cte.cfop "6353"
  cte.nature_of_operation "Prestacao de servico de transporte"
  cte.issuer tax_id: "11.444.777/0001-61", name: "TRANSPORTES LTDA", state_registration: "111111111111",
    tax_regime: :normal, address: {street: "Rua A", number: "100", district: "Centro", city_code: "3550308", zip: "01001-000"}
  cte.sender tax_id: "11.222.333/0001-81", name: "REMETENTE SA", state_registration: "222222222222",
    address: {street: "Rua B", number: "10", district: "Centro", city_code: "3550308", zip: "01001-000"}
  cte.recipient tax_id: "33.000.167/0001-01", name: "DESTINATARIO SA", state_registration: "333333333333",
    address: {street: "Rua C", number: "20", district: "Centro", city_code: "3304557", zip: "20000-000"}
  cte.taker :sender
  cte.freight total: "500.00" do |f|
    f.component "FRETE VALOR", "500.00"
  end
  cte.icms cst: "00", rate: "12.00"
  cte.ibs_cbs class_code: "000001"
  cte.cargo value: "15000.00", product: "Eletronicos" do |c|
    c.measure :kg, "1200.5"
  end
  cte.nfe "3526..."
  cte.road rntrc: "12345678"
end

waybill.issues                          # every problem found locally, as messages
signed = client.sign(waybill)           # store signed.xml before sending
result = client.authorize(signed)

if result.authorized?
  File.write(result.filename, result.proc_xml)       # <key>-procCTe.xml
  result.qr_code                                     # the URL for the DACTE's QR code
end
```

CT-e 4.00 (modelo 57) is authorized synchronously (`CTeRecepcaoSincV4`, GZip in Base64, one waybill per request). MG, MS, MT, PR and SP have their own authorizers; AP, PE and RR go to SVSP, and the remaining states (RS included) go to SVRS. `authorize` returns an `AuthorizationResult` (cStat 100 and 150 with a complete verified `protCTe` count as `authorized?`); `authorize!` raises `DfeRb::Cte::Rejected` or `ConsumptionBlocked`. Lost or incomplete answers and same-key duplicates (204) are resolved by consulting the key and verifying the stored protocol and digest (`result.recovered?`, or `Conflict` on mismatch). A `539` duplicate with a different access key raises `Conflict` immediately and exposes `error.existing_key` when SEFAZ's rejection text carries a matching key.

The gem derives the access key, `cUF`, `cMunEnv`/`xMunEnv`/`UFEnv` from the issuer's address, `cMunIni` and `cMunFim` from the sender and recipient when omitted, city names from IBGE, the modal code and its version, `indIEToma` from the active taker's IE, homologação party names (G002-G005), `vRec`, ICMS base and amount, DIFAL, IBS/CBS rates and `vTotDFe` (NT 2025.001, NT 2026.004), cargo measure labels, installment numbering and the authorizer's QR code. All six modals (`road`, `air`, `water`, `rail`, `pipeline`, `multimodal`) are grafted into the schema and validated against their own XSDs. Complementary (`cte.complement key`) and substitution (`cte.substitute key, change_taker: true`) CT-e are supported through the same builder.

### After authorization

```ruby
client.consult(key).status                            # :authorized, :canceled, :not_found or :rejected
client.cancel(key, protocol: result.protocol, reason: "Cancelamento por erro de digitacao")
client.correct(key, changes: [{group: "compl", field: "xObs", value: "Observacao corrigida"}])
client.deliver(key, protocol: result.protocol, document: "123456789", name: "Joao Silva",
  image: File.binread("assinatura.jpg"), nfe: ["3526..."])
client.cancel_delivery(key, protocol: result.protocol, event_protocol: delivery.protocol)
client.report_delivery_failure(key, protocol: result.protocol, reason: :recipient_not_found, attempt: 1)
client.cancel_delivery_failure(key, protocol: result.protocol, event_protocol: failure.protocol)
client.record_multimodal(key, text: "Registro de transbordo rodoviario concluido")
client.link_payment(key, protocol: result.protocol, method: :pix, transaction_id: "E1234567890",
  receiver_cnpj: "11444777000161", psp_cnpj_base: "11444777")
client.cancel_payment_link(key, protocol: result.protocol, event_protocol: link.protocol)
```

A taker registers or cancels a service disagreement (`610110` / `610111`) or claims presumed IBS/CBS credit on TAC/MEI transport (`211110`, routed exclusively to SVRS) with its own certificate:

```ruby
taker_client.disagree(key, reason: "Frete cobrado em desacordo com o combinado")
taker_client.cancel_disagreement(key, protocol: disagreement.protocol)
taker_client.claim_presumed_credit(key, base: "500.00", code: "01",
  ibs: {rate: "0.10"}, cbs: {rate: "0.90"}, payment_declaration: true)
```

Each event returns an `EventResult` with `registered?`, `protocol`, `proc_xml` (`procEventoCTe`) and `filename`. `correct` refuses locally the fields MOC 13.1 and NT 2024.001 bar from Carta de Correção (rej. 681).

### Contingency

- **SVC-RS / SVC-SP**: `cte.contingency :svc` picks the state's SVC emission type (`7` for MS, MT, SP and SVSP; `8` for MG, PR and SVRS) and routes `authorize`, `consult` and `cancel` to it. `client.status(contingency: true)` checks whether the SVC is active (`cStat` 113).
- **Off-line (NT 2026.004)**: `cte.contingency :offline, since: Time.now, reason: "Sem conexao com a internet"` emits with `tpEmis` 2 and signs the QR code's `sign` parameter with the certificate.

### Distribution

```ruby
distribution = DfeRb::Cte::Distribution::Client.new(certificate: certificate, uf: "SP", environment: :production)

batch = distribution.distribute(after: last_nsu)
batch.documents.each { |document| File.binwrite(document.filename, document.xml) }
batch.last_nsu; batch.more?; batch.retry_at
distribution.fetch_nsu("42")
```

It queries the Ambiente Nacional's `CTeDistribuicaoDFe` (NT 2015.002) and returns `WaybillDocument` (`cteProc`) and `EventDocument` (`procEventoCTe`) values with typed metadata and untouched XML. Because the CT-e distribution XSD defines `dhResp` without a timezone offset, `responded_at` is read in UTC while `response_xml` preserves the raw value verbatim.

## NFS-e

The NFS-e of the Padrão Nacional goes through the Sistema Nacional NFS-e. The issuer sends a signed DPS (Declaração de Prestação de Serviço) to the Sefin Nacional, which checks it against the national registers and the municipality's parameters and answers in the same call with the NFS-e, signed by it. Everything is JSON over mutual TLS with the certificate; the XML travels compressed with GZip in Base64. Homologação is the Sistema Nacional's "produção restrita".

```ruby
client = DfeRb::Nfse::Client.new(certificate: certificate, city: "5002704")   # or city: ["Campo Grande", "MS"]; homologação unless told otherwise

dps = client.build_declaration do |d|
  d.number 1                                     # series 1 unless given (1 to 49999 for your own application)
  d.provider cnpj: "12.345.678/0001-95", simples: :me_epp, simples_regime: :simples, special_regime: :none
  d.taker cnpj: "11.222.333/0001-81", name: "CLIENTE SA",
    address: {street: "Rua B", number: "1", district: "Centro", city_code: "5002704", zip: "79002-000"}
  d.service national_code: "010101", description: "Desenvolvimento de software sob encomenda", city_code: "5002704", nbs: "115021000"
  d.amount "1000.00"
  d.issqn :taxable                               # or :immune, :export, :not_levied
  d.withholding :none                            # or :taker, :intermediary
  d.approximate_taxes simples_rate: "6.00"       # or federal:, state:, municipal: (amounts), rates: {...}, :not_informed
  d.ibs_cbs operation_indicator: "030101", cst: "000", class_code: "000001"
end

dps.issues                                       # every problem found locally, as messages
signed = client.sign(dps)                        # store signed.xml before sending
result = client.issue(signed)

if result.issued?
  File.write(result.filename, result.nfse_xml)   # <key>-nfse.xml: the Sefin's NFS-e, with your DPS inside
  result.key; result.number; result.note.iss_amount; result.note.consult_url   # the DANFSe's QR code address
else
  result.errors.each { |error| puts "#{error.code} #{error.description}" }      # E0312 O código de tributação...
end
```

A note read back (`result.note`, `consult(key).note`, or `DfeRb::Nfse::Note.new(xml)` for one the ADN distributed to you as taker) gives its parties, service, dates and values, what was withheld as BigDecimal, and the DPS inside:

```ruby
note = DfeRb::Nfse::Note.new(xml)
note.provider.tax_id; note.provider.name; note.taker&.name          # Party: tax_id, nif, name, municipal_registration, city_code, email
note.service.national_code; note.service.description                 # Service: national_code, municipal_code, description, nbs, city_code, national_name
note.issued_at; note.competence_on; note.series; note.dps_number
note.service_amount; note.unconditional_discount; note.conditional_discount
note.iss_withholding                 # :none, :taker or :intermediary (tpRetISSQN)
note.withheld.irrf; note.withheld.to_h   # iss, social_security (vRetCP), irrf, csll, and pis and cofins when tpRetPisCofins says so
note.total_withheld                  # vTotalRet, else the sum
note.signature_problem               # nil when the Sefin's signature over infNFSe checks out, else why not
```

A note that comes as a file, from anyone, should be taken only when `signature_problem` is nil: it checks the Sefin's signature (the one referencing `NFS` + the key, not the DPS's inside), its digest and its value with the certificate it carries. `DfeRb::Signature.verify(xml, of: id)` checks the signature of a given Id in any document signed more than once.

`issue` returns a result whatever the Sefin says; `issue!` raises `DfeRb::Nfse::Rejected`. When the answer is lost (a timeout, an HTTP 5xx, a success without a readable NFS-e) or the Sefin says the series and number already produced a note (E0014), the client looks the DPS up by its Id and returns that note if it carries this same DPS (`result.recovered?`), or raises `Conflict` if it carries another. A note is this DPS's when its key is the one answered, its DPS has this Id, and the digest of its `infDPS`, computed by the gem, is the one signed.

`sign` checks every input against the client's layout: a `Declaration`, raw XML (which also gets the business rules) and a `SignedDeclaration` restored from storage. A DPS signed elsewhere must be signed by its issuer (E0718), in RSA-SHA256 or RSA-SHA1.

The gem derives the DPS Id (`"DPS"` + city + CNPJ or CPF + series + number), `tpAmb`, `dhEmi` (in the offset of the issuing city's state), `dCompet` (its day), `serie`, `tpEmit`, `verAplic`, `finNFSe`, `indDest` (1 when a `recipient` is given) and, for a MEI, `indTotTrib`. It derives no tax: the Sefin computes the ISSQN base, rate and amount from the municipality's parameters (`client.rates` tells them in advance), and the IBS/CBS from its calculator.

The provider issuing its own DPS is identified by CNPJ or CPF only: leave its name and address out, since the Sefin reads them from the registers (E0121, E0128). Give `municipal_registration:` only where the municipality's CNC holds one (E0116, E0120).

Local validation covers the layout and the rules of Anexo I that need nothing but the DPS: check digits, what each issuer type fills, the Simples Nacional and special regimes against rates and withholdings, values against the service's, the PIS and the COFINS against their base, the groups some services carry (construction, events, real estate), the IBS/CBS group's own consistency, and the dates. Each message names its code, such as `(E0600)`. What needs the national registers or the municipality's parameters stays with the Sefin. `strict: false` on `to_xml`, `issues`, `sign` and `issue` keeps only the layout checks.

### Layouts

Two versions of the 1.01 layout are in force, and they differ in shape. The client picks the one its environment validates, and `layout:` picks another:

| Layout | Package | Where | What changes |
| --- | --- | --- | --- |
| `:v1_01` | `nfse_1.01` (09/02/2026) | production | the layout every production issuer sends today |
| `:nt009` | `nfse_1.01_nt009` (20/10/2026) | produção restrita (homologação) | NT 009: alphanumeric CNPJ, `vAjusteBC` instead of `vDedRed` and `gReeRepRes`, `finNFSe` in `infDPS`, CST and cClassTrib straight under `IBSCBS/valores/trib`, `imovel` and `bensMoveis` reshaped, and the IBS/CBS group mandatory from the competence 01/10/2026 (E0855; the Simples Nacional's from 2027) |

Produção restrita refuses a DPS of the production layout (E1235), so build for the layout of the environment you send to. The English names are the same in both; a name whose group a layout lacks (`deductions` under NT 009, `base_adjustment` before it) is refused with a suggestion. When the CGNFS-e publishes NT 009's schedule for production, `Layouts::DEFAULTS` follows it in a release.

### After issuing

```ruby
client.consult(key).status            # :found, :not_found or :forbidden (you're no party to it); .note reads it
client.find(signed)                   # the key of the note a DPS produced (for its parties)
client.issued?(signed.id)             # whether a DPS produced a note, for anyone

client.cancel(key, reason: "Servico nao prestado por desistencia", code: :not_rendered)   # :error, :not_rendered, :other
client.request_cancellation(key, reason: "...")   # past the municipality's deadline: a fiscal review (101103)
client.confirm(key, as: :taker)                   # or :provider, :intermediary
client.reject(key, as: :taker, code: :values, reason: "Valor diverge do contratado")
client.event(key, type: 101101)                   # an event read back from the Sefin
client.events(key).documents                      # every event of a note, from the ADN
```

Each event is signed in the certificate holder's name (`CNPJAutor` or `CPFAutor`) and returns an `EventResult` with `registered?`, the Sefin's `event_xml` to archive, `filename`, and its `errors`.

To replace a note, issue a new DPS that names it: `d.replaces key, reason: :other, description: "..."`. The Sefin generates the new note and cancels the old one by substitution (event 105102) in the same call.

### Distribution and municipal parameters

```ruby
batch = client.distribute(after: last_nsu)   # NFS-e and events of interest to the certificate's holder
batch.documents.each { |document| File.write(document.filename, document.xml) }
batch.last_nsu; batch.caught_up?             # caught up: nothing after that NSU (E2220); rejected? and errors otherwise
client.distribute(after: 0, cnpj: "12345678000280")   # another establishment of the same root, or a proxy's grantor

client.agreement("5002704").national_issuer?              # does the municipality issue through the Sefin Nacional?
client.rates("5002704", service: "010101", on: Date.today).rate   # its ISSQN rate for a service
```

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

klass = DfeRb::Nfe::Tables.classification("200034")   # cClassTrib: cst, ibs_reduction, cbs_reduction, deferral?...
klass.presumed_credit?, klass.model?("65")              # ind_gCredPresOper, indNFCe (indNFe for "55")
klass.valid_on?(Date.today)                             # revoked codes stay, with their valid_until
DfeRb::Nfe::Tables.classification_list                  # all 173 of IT 2025.002 v1.71, revoked ones included

credit = DfeRb::Nfe::Tables.presumed_credit("04")       # cCredPres: also 4; nil if unknown
credit.ibs, credit.cbs                                  # => true, true: the group is required (false: barred, nil: blank in the table)
credit.on_note?, credit.deducted?, credit.payment_declaration?   # "Apropria via NF?", indDeduzCredPres, indDecPag
credit.referenced_classification                        # => "410017", the cClassTrib the referenced note carries
credit.valid_on?(Date.new(2027, 1, 1), tax: :ibs)       # each tax's days (ibs_from, cbs_from...); every code starts in 2027 or 2029
DfeRb::Nfe::Tables.presumed_credits                     # all 13
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
- an issuer without IE uses only CFOPs marked `indExcIBSCBS`, except on returns (I08-191, rej. 159, NT 2026.007; see [An issuer without IE](#an-issuer-without-ie))

An item's IBS/CBS codes are checked against the tables of IT 2025.002 (NT 2025.002):

- the `cClassTrib` exists and is in force on the issue date (UB14-10, rej. 1023), opens with its CST (UB14-20, rej. 1024) and may go on the note's model, `indNFe` or `indNFCe` (UB14-25, rej. 1025). A revoked code is kept with its end, so a note issued before it still passes.
- the operation's presumed credit (`IBSCBS/gCredPresOper`) is allowed by the `cClassTrib` (`ind_gCredPresOper`) unless the good is used (`indBemMovelUsado`) (UB120-20, rej. 1175); its `cCredPres` exists (UB122-10, rej. 1055); the IBS and CBS groups are given exactly where the code requires them and left out where it bars them (UB123-10 to UB127-20, rej. 1053, 1054, 1050, 1058); a used good's credit (cCredPres 04) doesn't exceed `vProd` (UB125-10, UB129-10); and an amount in suspensive condition comes only with cCredPres 04, the CBS's from 2027 and the IBS's from 2033 (UB126-10, UB130-10). The tables keep only each code's current indicators (IT 2025.002 v1.71, in production since 30/10/2026), so the rules that consult them (models, `ind_gCredPresOper`, the credit's tax groups) apply to notes issued from that day: an older note may carry a code an earlier version allowed.

The carrier required on fuel sales with `indComb` 2 (X04-10) is left to SEFAZ: it depends on a list of ANP product codes the gem doesn't ship.

### What a return references

NT 2025.002 v1.53 lets a return (`purpose :return`, `finNFe` 4) reference the note it returns in the header or on its items. Reference it in the header with `nfe.reference key: "..."`, once, or on each item with `i.referenced_dfe key: "...", item_number: 2` (`chaveAcesso` and `nItem`, which is optional):

```ruby
nfe.purpose :return
nfe.item do |i|
  i.cfop "6202"
  i.referenced_dfe key: sale_key, item_number: 1   # the item of the note it returns
end
```

The validator checks what the notes' own data says (the others go to SEFAZ, below):

- a return carries one header key at most, and so do a complement and the credit notes of types 01, 03 and 04 (B25-40, rej. 255; for a return from 09/11/2026 in homologação and 16/11/2026 in production). A return of several notes names each on its items.
- a return references its note, in the header or on every item but those of CFOP `5921` and `6921` (VC02-14, rej. 321; from 01/09/2026 in homologação and 03/11/2026 in production), and never in both (VC02-05 and VC02-14's observation, rej. 1010, from the same days).
- the items of a note reference one document, but for a return and the debit notes 03 and 07 (VC02-30, rej. 1130), and the items of a return one issuer, by its CNPJ base or CPF (VC02-40, rej. 1193; both from 09/11/2026 and 16/11/2026). The issuer of a Nota Fiscal Avulsa, whose key carries SEFAZ's CNPJ, isn't compared.
- the same key and item twice (VC02-20, rej. 1072) is checked once the NT dates it: `ReferenceRules::DUPLICATE_ITEM_REFERENCE_SINCE` is empty because v1.53 says "implementação futura". The same key on several items without `nItem` isn't a duplicate here, though the rule's observation reads so: it would refuse every return of several items of one note that leaves `nItem` out, which v1.53 allows.
- from 2027 a return or a complement that references only notes of 2027 on carries IBS/CBS (UB12-10's exception 1). The gem reads each key's AAMM, in the header and on the items. When the notes are of both years, or none can be read (a paper note), it asks nothing and SEFAZ judges.

Left to SEFAZ, because they consult its database: that the referenced note exists (3BA02-10, rej. 267), the return's total, ICMS and FCP against the notes returned (3BA02-50 to 3BA02-68, rej. 545, 546, 566, 567, 581), that the issuer of a referenced exit note is the return's recipient (VC02-50, rej. 1194, which needs the referenced note's direction) and the `nItem` that VC03-20 (rej. 1048) will require, "implementação futura", without the exception for a return that v1.53 announces.

### An issuer without IE

NT 2026.007 lets an issuer that pays only the IBS and the CBS, no ICMS (a contribuinte exclusivo do IBS/CBS), issue an NF-e with no state registration: leave `state_registration` out of `nfe.issuer`. SEFAZ confirms against the CCC that the CNPJ has no IE enabled. The rules start on 26/10/2026 in homologação and 16/11/2026 in production (v1.11), and the validator checks what the note says by itself:

- an NFC-e can't be issued without IE until 2033 (C17-42, rej. 156);
- the issuer is a CNPJ (C17-43, rej. 157) and gives no `IEST` (C18-50, rej. 158);
- no `ICMS` or `ICMSUFDest` group on an item (N01-10, rej. 161), but on a return and the credit note of type 03;
- the `IBSCBS` group on every item (UB12-11, rej. 162), a return included;
- only the CFOPs marked `indExcIBSCBS`, but on a return and the credit note of type 03 (I08-191, rej. 159).

Only the SVRS authorizes such a note (C17-11, rej. 166), so the client sends it there whatever its `uf`: `authorize`, the lot's return of `resume` and the lookup of its key after a lost answer. The key doesn't say the note has no IE, so ask for the later requests with `via: :svrs`, which routes the issuer's events there too (1P10-40):

```ruby
client.cancel(key, protocol: protocol, reason: "...", via: :svrs)
client.consult(key, via: :svrs)
```

A lot can't mix such notes with others, as it can't mix SVC ones. The Receita's LCC and SEFAZ's CCC registries are SEFAZ's to check, and the gem leaves them: that the CNPJ exists and is active at the Receita (12C02-10, 12C02-20, rej. 178, 179), that `CRT` matches its regime there (12C21-20, rej. 180), that the CCC knows no IE for it (1C17-02, 1C17-04, rej. 163, 164), the same for the recipient, the pickup and the delivery places (12E02 to 12G02, 5AF15 to 5BG17) and for the events (1P10-30, 1P10-32). In homologação v1.10 doesn't reject the issuer a CCC flags as a test one (`CCC.indContribTeste` 1), nor a recipient's state that differs from the Receita's.

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

## Deprecations

What SEFAZ stops accepting stays in the gem until it stops, and warns until then: once per process, to `$stderr`, as `[dfe_rb] DEPRECATION: ...`, naming the RV, the NT and the day. `DfeRb::Deprecation.silenced = true` turns the notices off.

| What | Why | Until | After |
| --- | --- | --- | --- |
| `Nfe::Client#authorize` with two or more notes (the asynchronous lot, `indSinc` 0) | RV GAP03a-6, rej. 129, NT 2023.002 v1.02 | Sent, with a notice, until 01/02/2027 in homologação and 05/04/2027 in production, by the request's clock or the notes' `dhEmi` | Raises `ValidationError` before sending. Send each note in its own call. |
| `Nfe::Client#resume`, the receipt query (`:authorization_return`, `Requests.lot_return`) | It collects an asynchronous lot's answer, and no lot is accepted | Works, with a notice, for a lot accepted before the day above | Nothing issues a receipt; SEFAZ may stop answering old ones |
| `inutilize` in AC, BA and SP | Ajustes SINIEF 38/2026 and 40/2026, RV I01a (rej. 998) | Sent until 11/11/2026 | Raises `Unsupported` before sending (this one is not a warning: the service is gone) |

The lot (`authorize` with an Array of two or more notes), `resume` and `Requests.lot_return` are removed in a release after 05/04/2027, once SEFAZ no longer answers old receipts. The CHANGELOG announces it first, and a release that removes them says so.

## Testing

`bundle exec rake` runs the specs (no network) and Standard. Live checks against homologação are opt-in:

```sh
DFE_RB_LIVE=1 DFE_RB_PFX=empresa.pfx DFE_RB_PFX_PASSWORD=... bundle exec rspec spec/live
```

They confirm the SOAP contract and every service with your certificate, including national distribution and a mixed manifestation lot. Distribution checks consume your homologação query quota and can return an existing 656 block; set `DFE_RB_LIVE_LAST_NSU` to your coordinated cursor. Optional `DFE_RB_LIVE_NSU` and `DFE_RB_LIVE_DISTRIBUTION_KEY` control targeted checks. The full lifecycle example (authorize, consult, correct, cancel, inutilize) also needs an issuer registered at the state: see the header of `spec/live/nfe_homologacao_spec.rb`. The lifecycle examples authorize and cancel a DANFE Simplificado Tipo 2 too, on-line and off-line. `spec/live/nfce_homologacao_spec.rb` checks every NFC-e authorizer and, with the same issuer variables, authorizes, cancels and inutilizes NFC-e, issues one off-line and cancels another by substitution; the issuer must be accredited for the NFC-e at its state. `spec/live/mdfe_homologacao_spec.rb` does the same for the MDF-e; its lifecycle (authorize, consult, add a driver, close, cancel) needs an issuer accredited for the MDF-e and an NF-e to carry, as its header says. `spec/live/nfse_homologacao_spec.rb` checks the Sistema Nacional NFS-e's produção restrita with any certificate (a DPS and an event reach the registers' checks, lookups, distribution, parameters); its lifecycle (issue, find, cancel) needs an issuer registered in a municipality of the national issuer, set in `DFE_RB_LIVE_NFSE_CITY`.

## Legislation

Built from MOC 7.0 (Anexo I v7.03) and the NTs up to NT 2026.009, with the layout read from the `PL_010f_v1.04` schema package. Distribution uses `PL_NFeDistDFe_104` (NT 2014.002 v1.40); recipient manifestations follow NT 2020.001 v1.60, the unchanged official manifestation detail schemas, and the generic event schemas from `PL_010d_v1.03` for alphanumeric identities. Contingency follows Anexo III of the MOC and NT 2014.001 v1.41 (EPEC), with each state's SVC taken from the Portal Nacional's "Relação de Serviços Web", which has changed since Anexo III was written; consulta cadastro follows MOC 5.6 and `PL_010d_v1.03`. Where the MOC and later NTs disagree, the NTs and the schema win (synchronous authorization only, 7-day late-issue window, 4-digit `cStat`, alphanumeric CNPJ, no inutilização in AC, BA and SP).

The NFC-e follows the same MOC and Anexo I, the rules each NT gives modelo 65 (NT 2015.002, 2018.004 for the cancellation by substitution, 2023.001, 2023.002 v1.01, 2023.003 v1.40, 2024.001, 2025.001 v1.03 for the QR code version 3, NT 2025.002, 2026.002 v1.11), with the parameters of the QR code as NT 2026.003 tabulates them and Anexo IV for the off-line contingency. The DANFE Simplificado Tipo 2 follows NT 2026.002 v1.11 and NT 2026.003 v1.00. Where an NT lists fewer CFOPs than another, the gem takes the wider list. Its web services come from the SVRS DF-e portal's "Relação de Serviços Web" (MG, missing there, from its own authorizer's answer), and the QR code and consultation addresses from the Portal Nacional da NFC-e (`nfce.encat.org`).

The NFS-e follows the Anexos I and II of the Sistema Nacional NFS-e (v1.01 of 09/02/2026 and 22/01/2026 for production, and their produção restrita editions of 20/10/2026, NT 009 v1.01), with the layouts read from the packages `nfse-esquemas_xsd-v1-01-20260209` and `esquemas_prod_restrita_20261020`. Its API contract is the OpenAPI the Sefin Nacional, the ADN Contribuinte and the Parametrização publish (read on 18/11/2026, behind mutual TLS), with the contributors' manuals of the Emissor Público Nacional (v1.2) and of the ADN. The DPS is signed in RSA-SHA256, which produção restrita takes. The DANFSe (NT 008) is not printed; `Note#consult_url` gives its QR code's address.

The MDF-e is built from the MOC MDF-e 3.00b (with its Anexo I) and the NTs up to NT 2026.001, with the layout read from the `PL_MDFe_300b_NT012025_1.05` schema package; its distribution follows NT 2015.002 and `PL_MDFeDistDFe_100`. Its web service addresses are the SVRS portal's "Relação de Serviços Web".

## Keeping up with official publications

Everything below is a copy of something the government publishes, so it goes stale. Each change ships in a release of the gem.

Tables regenerated by `script/update_tables` (into `lib/dfe_rb/nfe/data`; `municipalities.tsv`, which the MDF-e uses too, into `lib/dfe_rb/data`):

| File | Source | How | When |
|---|---|---|---|
| `municipalities.tsv` | IBGE localities API (`servicodados.ibge.gov.br`) | downloaded on every run, or `--ibge file.json` | a municipality is created or renamed |
| `classifications.tsv` | cClassTrib table of IT 2025.002, on the SVRS DF-e portal (`dfe-portal.svrs.rs.gov.br/DFE/ClassificacaoTributaria`) | downloaded on every run, or `--svrs page.html` | each new version of the IT |
| `cred_pres.tsv` | cCredPres table of IT 2025.002, the `.xlsx` the SVRS "Conformidade Fácil" portal lists (`dfe-portal.svrs.rs.gov.br/CFF/Documentos`) | downloaded on every run, or `--cred-pres cCredPres.xlsx` | each new version of the IT |
| `cfop.tsv` | CFOP table of IT 2023.002, the `.xlsx` on the Portal Nacional da NF-e | `--cfop tabela.xlsx` | each new version of the IT |
| `tipi.tsv` | TIPI, the `Tipi.xlsx` on gov.br/receitafederal | `--tipi Tipi.xlsx` | each decree or ADE that changes the TIPI |

```sh
script/update_tables --cfop tabela_cfop.xlsx --tipi Tipi.xlsx
```

Every run rewrites the IBGE, SVRS and CONFAZ tables from the network; the CFOP table and the TIPI have no stable address and are left alone unless their file is given. `--only classifications,cred_pres` regenerates just the tables named, and `--diff` prints what would change instead of writing. `bundle exec rake tables:check` prints what the current IT 2025.002 tables would change, without writing. Review the `git diff` of the data before committing, and update the row counts the table specs assert.

Every document the gem follows (MOC, NT, IT, schema package and table source) has a row in [`lib/dfe_rb/data/manifest.yml`](lib/dfe_rb/data/manifest.yml): its version, publication and production dates, where it's implemented and the SHA-256 of the file read. A spec fails when a shipped table or schema package has no row. [CONTRIBUTING.md](CONTRIBUTING.md) has the checklist to follow before a release.

Edited by hand:

| What | Where | Source | When |
|---|---|---|---|
| Payment methods (`tPag`) and the day each starts | `data/payment_methods.tsv`; friendly names in `Names::ENUMS["tPag"]`; `Tables::DEFERRED_PAYMENTS` | "Meios de pagamento" table of the Portal Nacional da NF-e (IT 2024.002) | each new version of the IT |
| Card brands (`tBand`) | `data/card_brands.tsv` | "Bandeiras" table of the Portal Nacional da NF-e | a new brand |
| XSD packages | `lib/dfe_rb/xml/schemas` (copied unchanged; versions listed in its `README.md`) | Portal Nacional da NF-e, "Esquemas XML" | each schema package (`PL_010...`), usually with an NT |
| English names of new fields | `lib/dfe_rb/nfe/names.rb` | the new schema package | with the XSDs |
| Validation and derivation rules | `validator.rb`, `calculator.rb`, `totals.rb`, `resolver.rb` (each rule cites its RV and NT) | Anexo I of the MOC and the NTs | each NT; "Legislation" above names the last one applied |
| Dates a rule starts | `Validator::IBS_CBS_SINCE`, `PAPER_REFERENCES_BARRED_SINCE`, `CONSUMER_REFERENCES_BARRED_SINCE`, `ReferenceRules::RETURN_REFERENCE_SINCE`, `REFERENCE_RULES_SINCE`, `DUPLICATE_ITEM_REFERENCE_SINCE`, `NoIeRules::NO_IE_RULES_SINCE` | NT 2025.002, NT 2026.002 and their successors | an NT moves a date |
| States barred from the EPEC | `States::EPEC_BARRED` | NT 2014.001 (RV 2P10-20) | an Ajuste SINIEF adds or removes a state |
| Lists a rule consults | in `validator.rb`: `MEI_RETURN_CFOPS`, `RETURN_OTHER_CFOPS`, `NATURAL_GAS_RETURN_CFOPS`, `DIFAL_EXEMPT_CFOPS`, `DIFAL_FUEL_ANP_CODES`, `DIFAL_EXEMPT_ICMS` | the RVs they name (I08-140, I08-141, NA01-20) | an NT rewrites the rule |
| IBS/CBS standard rates by year | `Rates::IBS_CBS`, and the CBS reference rate of 2027 and 2028 in `Rates::CBS_REFERENCE` (less `CBS_TRANSITION_DISCOUNT`); nothing after 2028 | IT 2025.002 §05, the Senate's resolution or the TCU's rate (LC 214/2025, art. 349), and the laws that set each year's rates | yearly, before the first issue of the year; for 2027, on 22/12/2026 at the latest |
| Interstate ICMS rates and the DIFAL partition | `Rates::SOUTH_SOUTHEAST`, `IMPORTED_ORIGINS`, `PARTITION` | Senate Resolutions 22/1989 and 13/2012, EC 87/2015 | a new resolution (rare) |
| NFC-e web services and each state's NFC-e authorizer | `nfce/endpoints.rb` (`AUTHORIZERS`, `PATHS`), `Nfce::States::OWN_AUTHORIZER` | "Relação de Serviços Web" (`dfe-portal.svrs.rs.gov.br/Nfce/Servicos`) | a state moves to or from the SVRS, or an address changes |
| NFC-e QR code and consultation addresses | `Nfce::Endpoints::QR_CODE`, `CONSULT` | Portal Nacional da NFC-e, "URL por UF utilizada QR code" and "... para consulta chave" | a state moves its consultation |
| Lists the NFC-e rules consult, most of which the DANFE Simplificado Tipo 2 shares | in `nfce/validator.rb`: `CFOPS`, `SALE_CFOPS`, `ST_CFOPS`, `CSTS`, `CSOSNS`, `STATE_CFOPS`, `BARRED` and `BARRED_ITEM` (both), `BARRED_NFCE` and `BARRED_NFCE_ITEM` (modelo 65 only) | the RVs of modelo 65, NT 2026.002 and the NTs that amend them | an NT changes a rule of modelo 65 or of `tpImp` 6 |
| Web service addresses, each state's authorizer and SVC, and who offers consulta cadastro | `nfe/endpoints.rb` (`AUTHORIZERS`, `PATHS`, `CONTINGENCY`, `REGISTRY_URLS`, `REGISTRY_SVRS`), `States::OWN_AUTHORIZER`, `SVAN` and `SVC_AN`, `nfe/distribution/endpoints.rb` | "Relação de Serviços Web" (`dfe-portal.svrs.rs.gov.br/Nfe/Servicos` and the Portal Nacional) | a state moves to or from a SEFAZ Virtual, or an address changes |
| Status codes the client acts on | `nfe/status_codes.rb` | Anexo I §4.4 and the NTs | an NT adds a `cStat` that changes the flow |
| NFS-e layouts and which one each environment validates | `lib/dfe_rb/xml/schemas/nfse_*`, `Nfse::Layouts::ALL` and `DEFAULTS` | gov.br/nfse, "Documentação Atual" and "Produção Restrita" | a new schema package, or NT 009's production schedule |
| NFS-e rules | `nfse/validator.rb` (each rule cites its E-code), with `CONSTRUCTION`, `REAL_ESTATE`, `OPERATION_TYPE_SERVICES` and the dates `IBS_CBS_SINCE`, `IBS_CBS_REQUIRED_SINCE`, `IBS_CBS_REQUIRED_SIMPLES_SINCE` | Anexo I of the Sistema Nacional NFS-e and the NTs SE/CGNFS-e | each edition of Anexo I |
| NFS-e API hosts | `nfse/endpoints.rb` (`BASES`, `SERVICES`) | the OpenAPI documents of the Sefin Nacional and the ADN | an address changes |
| ICP-Brasil root CAs | `lib/dfe_rb/certs/icp-brasil.pem` (v5, v10, v11, v12; v5 expires 02/03/2029) | `acraiz.icpbrasil.gov.br/credenciadas/RAIZ` | ITI publishes a new root, or one expires |

State tables (internal ICMS and FCP rates, cBenef x CST, MVAs) aren't shipped, so they are the application's to keep current.

After an update: `bundle exec rake`, then the live checks against homologação when a schema, a rule or an address changed.
