# Changelog

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
