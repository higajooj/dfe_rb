# Bundled official schemas

- `nfe_4.00`: NF-e layout from PL_010f_v1.04 (emission).
- `PL_NFeDistDFe_104`: distribution request/response and summary layouts, NT 2014.002 v1.40. `xmldsig-core-schema_v1.01.xsd` is the unchanged signature dependency from PL_010d_v1.03.
- `event_1.00`: generic event request/response/process layouts and dependencies from PL_010d_v1.03/Evento. These support alphanumeric CNPJ, access keys and event IDs, and four-digit statuses.
- `cad_2.00`: consulta cadastro request and answer (`consCad`, `retConsCad`) from PL_010d_v1.03/CadConsultaCadastro. The request is validated; answers are read by tag, since some states deviate from the schema's namespaces.
- `Evento_ManifestaDest_PL_v1.01`: unchanged official manifestation detail schemas (`e210200`, `e210210`, `e210220`, `e210240`). The manifestation client uses only these detail validators. Its envelope uses the generic event schemas above.

These packages were copied unchanged from the official material in `nfe-archiver-ruby/notes/nfe/schemas`. NT 2020.001 v1.60 gives the current sequence and deadline rules where older schema annotations keep historical wording. Incoming documents are read by metadata readers that don't depend on the root or version, and a schema filename in a response is never used to open files or resources.
