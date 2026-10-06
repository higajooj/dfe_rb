# Changelog

## 0.8.0

- SVC contingency (Anexo III): `nfe.contingency :svc, since:, reason:` issues a note for the issuer's SEFAZ Virtual de Contingência (`tpEmis` 6 for the SVC-AN, 7 for the SVC-RS, from `States.contingency`), and `authorize`, `resume`, `consult` and `cancel` go to the SVC for such a note. `client.status(contingency: true)` tells whether the state has its SVC active (`online?`, `deactivating?`, `disabled?`). `via: :home` or `:contingency` picks the authorizer on `consult`, `cancel` and `correct`; a carta de correção goes to the state's own by default, as the SVC takes none.
- EPEC (evento 110140, NT 2014.001 v1.41): `client.epec(signed)` registers at the Ambiente Nacional the summary of a note issued with `nfe.contingency :epec`; `client.prepare_epec` returns the signed event to store first. Refused locally for a note that isn't `tpEmis` 4 and for issuers of PR and PB (Ajuste SINIEF 25/2026).
- Consulta cadastro (`NfeConsultaCadastro`, MOC 5.6): `client.taxpayers(uf:, cnpj:)` (or `cpf:`, `ie:`) returns the registrations of a taxpayer in a state's ICMS cadastro: IE, situation, NF-e accreditation, name, regime, CNAE, dates and address. `Endpoints.registry?(uf)` tells whether the state has the service; the others raise `DfeRb::Nfe::Unsupported`.
- Flag locally what a note in contingency must and must not say: `dhCont` and `xJust` (RVs B28-10, B28-20), a contingency that starts after the note, the wrong SVC for the issuer's state (B22-60) and off-line contingency without the DANFE Simplificado Tipo 2 (B22-10).

## 0.7.0

- Derive the bases an item's own values fix, once the rate is given: ICMS `vBC` (the operation value, with the IPI for a final consumer, less `pRedBC`; `modBC` 3), `vBCFCP`, `vBCFCPST`, the DIFAL's `vBCUFDest` and `vBCFCPUFDest`, the IPI's `vBC`, PIS and COFINS `vBC` (without the item's own ICMS) and `vCredICMSSN` from `pCredSN`.
- Derive `vBCST` from a given `pMVAST` (and `pRedBCST`): (operation value + IPI) x (1 + MVA), Conv. ICMS 142/2018, with `modBCST` 4. It used to be left to the issuer; a state that composes its base otherwise still gives `st_base`.
- An interstate item with CST 00, 10, 20 or 70 takes the rate the law fixes without a base being given.
- `nfe.freight`, `nfe.insurance`, `nfe.discount` and `nfe.other_expenses` spread an invoice-level amount over the items by value, to the cent, before the taxes are computed (`DfeRb::Nfe::Apportion`).
- `DfeRb::Nfe::Rates.pis_cofins(regime)` and `Rates.simples_icms_credit(revenue_12m:, annex:)`, the `pCredSN` of LC 123/2006.
- IBS/CBS is required in production since 03/08/2026 for regime normal and since 04/01/2027 for the Simples Nacional and the MEI (NT 2025.002 v1.51, RV UB12-10). Production used to be treated as not started, so a note SEFAZ rejects with 1115 passed local validation.
- `tPag` 05 and 17 are accepted from the table's start, not from 01/07/2024: IT 2024.002 only renamed them (Cartão da Loja, PIX Dinâmico), and a note issued before that day with either was flagged.

## 0.6.0

- Ship the TIPI's IPI rates (Decreto 11.158/2022 and its updates), looked up with `DfeRb::Nfe::Tables.ipi_rate(ncm, ex)` and listed with `Tables.ipi_rates`. `script/update_tables --tipi Tipi.xlsx` regenerates them from the Receita Federal's spreadsheet.
- Derive `pIPI` from the TIPI line of the item's `NCM` and `EXTIPI` when `IPITrib` has a base and no rate, on a normal operation (`finNFe` 1). An NT line, an NCM the TIPI lacks and a per-unit IPI get none.
- Ship the payment methods (`tPag`, IT 2024.002 v1.11, with the day each code starts) and the card brands (`tBand`): `Tables.payment_method`, `Tables.payment_methods`, `Tables.card_brands`.
- Flag a `tPag` that isn't in the table or isn't accepted yet on the issue date.
- `kind: :automatic_pix` (23) and `:book_transfer` (24).
- `DfeRb::Nfe::Rates.adjusted_mva(mva, interstate:, internal:)`: the ST margin adjusted for the interstate rate (Conv. ICMS 142/2018). `vBCST` is still yours to give.

## 0.5.0

- Check every item's CFOP against the CFOP table before sending: unknown, out of force or not for NF-e (I08-04, rej. 770); a return or a credit note of type 03/06 without a devolução CFOP, accepting 1949/2949 on any of them and 5949/6949 for natural gas (I08-140 per NT 2026.009, rej. 327); a MEI's return outside its six CFOPs (I08-141, rej. 1179); an issuer without IE outside the `indExcIBSCBS` CFOPs (I08-191, rej. 159).
- Require `icms_destination` (DIFAL) on an interstate sale to a non-contributor final consumer, with every NA01-20 exception (retorno and remessa CFOPs, 6552/6922/6929, `ICMSPart`, exempt or untaxed ICMS, Simples Nacional, delivery in the issuer's state, non-petroleum fuels, returns of pre-2016 notes referenced in `NFref` or the item's `DFeReferenciado`, production notes issued before 01/07/2016...) (rej. 694).
- Require the `comb` group on a fuel CFOP (LA01-20, rej. 660) and a transport CFOP in `retTransp` (X16-10, rej. 722).
- CFOP messages name the CFOP's title: `6916 (Retorno de mercadoria ou bem recebido para conserto…)`.
- Open RC2-40 `.pfx` files on precompiled Rubies (mise, rv...), whose bundled OpenSSL looks for the legacy provider in the build machine's path: the provider is retried from the system's OpenSSL 3 modules directory.
- Derive `tpNF` 0 (entry) when every item has an entry CFOP (`1102`) or the note is a credit note, 1 on a debit note whatever its CFOPs, and `finNFe` 5/6 from `credit_note_type`/`debit_note_type` (RV I08-10, B25-110, B25-120, B25.1-10, B25.2-10). Both used to default to an exit note of purpose 1, which SEFAZ rejects.
- Flag a credit note that isn't an entry (B25-110, rej. 1161) and a debit note that isn't an exit (B25-120, rej. 1162).
- Flag a devolução CFOP (`indDevol`) on a note that isn't a return, a complement or a credit note of type 03/04/06 (RV I08-144, rej. 328), telling you to set `purpose :return`.
- `DfeRb::Nfe::Tables.cfops` lists the CFOP table, optionally `matching:` title words (case and accents ignored) and a code prefix; `Tables.cfop` also takes `"5.102"` and `5102`.
- A `Cfop` tells its direction (`entry?`, `exit?`), `scope` (`:internal`, `:interstate`, `:foreign`) and `valid_on?(date)`, up to but not including its end date (IT 2023.002).
- README documents the official tables and maps each CFOP method to its IT 2023.002 indicator.
- Leave the interstate ICMS rates (`pICMS`, `pICMSInter`) to the issuer on an entry note, whose goods don't leave the issuer's state, and on an item with a retorno or anulação CFOP, even on a normal note: it carries the rates of the operation it refers to (RV N16-04, N16-20, NA09-30). A retorno also leaves `pICMSInterPart`, which follows the referenced note's year (NA11-10); an anulação still gets this year's. An entry from GO into SP used to get SP's outbound 7%, and `6916` this year's rates. IBS/CBS standard rates are still filled, as their rules have no such exception.
- Ship the CFOP table of IT 2023.002 (validity, the nine indicators and the title), looked up with `DfeRb::Nfe::Tables.cfop`.
- `script/update_tables` takes `--ibge`, `--svrs` and `--cfop` flags; `--cfop` regenerates `cfop.tsv` from the Portal Nacional's `.xlsx`.

## 0.4.2

- Fill the interstate ICMS rate, the DIFAL rates and the IBS/CBS standard rates only on a normal operation (`finNFe` 1); a return derived 12% where the original sale was taxed at 7%.
- Stop deriving `vBCST`: how discounts and charges enter the ST base is state law. `vICMSST` is still derived from a given `vBCST`.
- Classifications taxed in `gTribRegular` (e.g. 550001, suspension) get zero main IBS/CBS rates, and a deferral CST (510) gets no amounts until `gDif` is given; both used to get ordinary rates and full amounts. The shipped cClassTrib table now keeps `ind_gDif` and `ind_gTribRegular`, and `script/update_tables` follows the SVRS page's new address.
- Validate `gTribRegular` (rej. 1065, 1114), `gDif` (rej. 1029/1030, 1044/1083, 1061/1090) and zero main rates under regular taxation (rej. 1026, 1036, 1037).
- Compute from operands as the XML prints them (amounts with 2 places, rates and quantities with 4), so an amount always agrees with its printed base and rate.
- README lists the inputs that are state law and never derived; the live checks take the internal ICMS rate from `DFE_RB_LIVE_ICMS_RATE`.
- Validation compares against the expected amount rounded to cents, skips amounts the gem can't compute (IS with `adRemIS`), and takes the issue year from `dhEmi`'s own offset (a note issued on 31/12 evening was checked as the next year's).

## 0.4.1

- Write a derived `pICMSInter` as the schema's enumeration (`"12.00"`, not `"12"`); interstate DIFAL notes failed schema validation.
- Live homologação checks for invoices built from derived values (internal sale and interstate DIFAL), verified against SEFAZ-MS.

## 0.4.0

- Derive every field whose value is deterministic, keeping whatever is given explicitly:
  - per-item tax amounts from base × rate: ICMS, FCP, CST 51 deferral, ST by margin, IPI, PIS/COFINS, DIFAL, IS, and IBS/CBS (base, deferral, effective rate, amounts)
  - `vItem`, `vNFTot` and `ISTot`
  - the interstate ICMS rate, the DIFAL partition and the IBS/CBS standard rates of the issue year
  - the IBS/CBS CST and rate reduction from `cClassTrib`
  - IBGE city names and codes
  - 3-digit CFOPs completed to fit the operation
  - single-payment and billing amounts, and installment numbers
- `technical_contact:` on `Client` and `Invoice` fills `infRespTec` and computes `hashCSRT` from the CSRT.
- Ship the IBGE municipality and cClassTrib tables, with `script/update_tables` to refresh them.
- Validate supplied FCP, DIFAL, IS, IBS/CBS amounts, effective rates, `vItem`, `vNFTot` and `hashCSRT` against the values SEFAZ recomputes.

- Fix the national homologação host for distribution and manifestation: `hom1.nfe.fazenda.gov.br` (`hom.` answers 404).
- Read manifestation answers from AN's `<nfeRecepcaoEventoNFResult>` body; every manifestation raised `TransportError` before.
- Live lifecycle check covers regime normal issuers (ICMS 00 plus IBS/CBS), sends `infRespTec` and the recipient IE, and is verified end to end against SEFAZ-MS homologação.

## 0.3.0

- Replace the distribution/awareness PoC with `DfeRb::Nfe::Distribution::Client`: sequential distribution, targeted NSU/key queries, and all four explicit recipient manifestation types. Defaults to homologação and the certificate's identity; accepts CPF and numeric/alphanumeric CNPJ, branch identities, national endpoint overrides, and the shared injectable transport.
- Immutable distribution results with cursor/cooldown guidance and typed document metadata. Exact decoded XML is preserved for summaries, complete invoices, arbitrary distributed events, historic layouts, and unknown document types. Strict, bounded Base64/Gzip/XML decoding raises contextual `InvalidResponse` rather than silently losing a document.
- Portable `SignedManifestation` objects with restoration, local validation and signature/author verification; batches of up to 20 events, matched responses in input order, sequence 2 for conclusive types, typed registration/duplicate/rejection results, and archival `procEventoNFe`.
- Add the national distribution SOAP wrapper/result contract to `DfeRb::Transport`, bundle current distribution and generic event schemas, and add opt-in homologação contract checks.
- **Breaking:** remove `DfeRb::Dfe`, `DfeRb::Manifest`, their sample SOAP templates, Savon and its logging configuration helpers. Applications own cursor persistence, scheduling, cross-process quota coordination, and explicit manifestation decisions; no automatic queries or manifestations are added.
- `DfeRb::Certificate.tax_id_of(x509)` reads the holder identity of a public signing certificate without its private key.

## 0.2.0

- **NF-e emission (modelo 55, layout 4.00)** in production and homologacao: `DfeRb::Nfe::Client` with `status`, `sign`, `authorize` (synchronous single note or asynchronous lot of up to 50, with receipt polling), `consult`, `cancel` (110111), `correct` (CC-e 110110) and `inutilize`, plus `raw` for anything else.
- Invoice builder (`DfeRb::Nfe::Invoice`): readable English names with the official tag names (also snake_case) as aliases; input by block, hash or keywords. Defaults and derived fields (access key, `idDest`, `indIEDest`, totals, IBS/CBS totals, change, homologacao recipient name). The layout is read from the official XSD, so every field of NF-e 4.00 is reachable, including IBS/CBS (Reforma Tributaria).
- Local validation before sending: value formats, the official XSD (bundled `PL_010f_v1.04`) and unambiguous business rules from Anexo I and the NTs. `strict: false` skips the business rules.
- Lost or ambiguous answers (timeouts, duplicate rejections 204/539) are resolved by consulting the key and adopting the stored protocol when the document is the same.
- `nfeProc`, `procEventoNFe` and `ProcInutNFe` are assembled from the exact signed bytes.
- `DfeRb::Certificate` (PKCS#12/PEM, CNPJ/CPF from the ICP-Brasil extension, CA chain, RC2-40 files via the OpenSSL legacy provider) and `DfeRb::TaxId` (numeric and alphanumeric CNPJ, CPF).
- `DfeRb::Transport`: mutual-TLS SOAP 1.2 over `Net::HTTP` without WSDL downloads, with timeouts and log filtering.
- The vendored `DfeRb::Signer` gained `x509_certificate:` and `enveloped_first:` signing options (defaults unchanged).

## 0.1.0

- Extracted from `nfe-archiver-ruby`'s `vendor/nfe_services`: `DfeRb::Dfe` (NFeDistribuicaoDFe) and `DfeRb::Manifest` (NFeRecepcaoEvento4 awareness events).
- Bundles the NF-e-patched `signer` 1.9.0 as `DfeRb::Signer`.
