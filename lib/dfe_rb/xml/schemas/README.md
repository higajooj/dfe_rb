# Bundled official schemas

- `nfe_4.00`: NF-e layout from PL_010f_v1.04 (emission).
- `PL_NFeDistDFe_104`: distribution request/response and summary layouts, NT 2014.002 v1.40. `xmldsig-core-schema_v1.01.xsd` is the unchanged signature dependency from PL_010d_v1.03.
- `event_1.00`: generic event request/response/process layouts and dependencies from PL_010d_v1.03/Evento. These support alphanumeric CNPJ, access keys and event IDs, and four-digit statuses.
- `cad_2.00`: consulta cadastro request and answer (`consCad`, `retConsCad`) from PL_010d_v1.03/CadConsultaCadastro. The request is validated; answers are read by tag, since some states deviate from the schema's namespaces.
- `Evento_ManifestaDest_PL_v1.01`: unchanged official manifestation detail schemas (`e210200`, `e210210`, `e210220`, `e210240`). Only these detail validators are used for the new manifestation client; its envelope uses the current generic event schemas above.

The current packages were copied from the official material collected in `nfe-archiver-ruby/notes/nfe/schemas`. Schema files are preserved unchanged. NT 2020.001 v1.60 provides the current sequence and deadline rules where older schema annotations retain historical wording. Incoming documents are parsed by root/version-independent metadata readers; returned schema filenames are never used to open files or resources.
