# Changelog

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
