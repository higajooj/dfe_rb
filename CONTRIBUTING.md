# Contributing

`bundle exec rake` runs the specs and Standard. The live checks against homologação (`DFE_RB_LIVE=1 bundle exec rspec spec/live`) need a registered issuer's certificate and never run by default. Never point them at production.

Every rule, table and schema the gem ships copies something the government publishes, and each copy is listed in [`lib/dfe_rb/data/manifest.yml`](lib/dfe_rb/data/manifest.yml), one row per document: its version, publication and production dates, where it's implemented and the SHA-256 of the file read. A rule cites its RV and NT in a comment; the manifest says which revision of that NT it follows.

## Release checklist

Before tagging a release:

1. **Check the publication lists.** Open each list and compare it with the manifest's `current` versions:
   - Portal Nacional da NF-e, "Notas Técnicas" (`www.nfe.fazenda.gov.br/portal/listaConteudo.aspx?tipoConteudo=04BIflQt1aY=`) and "Informes Técnicos" (`...?tipoConteudo=hXzemuyNHW4=`), and the news on its home page, where postponements are announced;
   - the SVRS "Conformidade Fácil" documents (`dfe-portal.svrs.rs.gov.br/CFF/Documentos`), which carry the IT 2025.002 tables (cClassTrib, cCredPres);
   - the MDF-e portal (`dfe-portal.svrs.rs.gov.br/Mdfe`), its documents and notices;
   - the Portal Nacional da NFC-e (`nfce.encat.org`) for the QR code addresses.
2. **Update the tables.** `bundle exec rake tables:check` prints what the current cClassTrib and cCredPres would change, without writing. `script/update_tables` regenerates them (see "Keeping up with official publications" in the README). Never delete a revoked code: the table keeps it with its end date, so older notes still validate.
3. **Apply each new NT or IT.** Read what its version table says changed, then update the rules, schemas and constants it touches, citing the RV and the NT's version.
4. **Update the manifest.** For every document read or updated, record its row: `version` (what the gem follows), `current` (the newest published, when the gem lags behind), `published`, `production`, `implemented_in` and the `sha256` of the PDF, ZIP or XLSX read (`sha256sum file`). A newly published document the gem doesn't follow yet gets a row with `status: pending`. Move anything resolved out of `awaiting`.
5. **Run `bundle exec rake`.** The manifest spec fails if a table or schema package has no row, a path is missing or a hash is malformed. Then run the live checks when a schema, a rule or an address changed.
6. **Write the changelog entry** and bump `DfeRb::VERSION`.
