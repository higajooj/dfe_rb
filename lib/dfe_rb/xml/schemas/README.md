# Bundled official schemas

- `nfe_4.00`: NF-e layout from PL_010h_v1.03 (13/11/2026; emission): the Simples Nacional's IBS/CBS (NT 2026.005), the net value of the product (NT 2026.008) and the link to the payment transaction (NT 2026.006). `nfe_v4.00.xsd`, `tiposBasico_v4.00.xsd` and the signature schema are unchanged from PL_010f_v1.04.
- `Evento_PL_010h_v1.03`: the Evento folder of PL_010h_v1.03, unchanged: the detail schemas of event 110300 (payment link, NT 2026.006) and 412140 (Simples Nacional taxation, NT 2026.005), and `e110001` with the `tiposBasico_v1.03.xsd` they include. The package has no `envEventoNFe` schema (no `envEventoNFe_v9.99.xsd` is published): an event's detail is checked against its own schema and the envelope against `event_1.00`'s, whose `detEvento` takes any content.
- `PL_NFeDistDFe_104`: distribution request/response and summary layouts, NT 2014.002 v1.40. `xmldsig-core-schema_v1.01.xsd` is the unchanged signature dependency from PL_010d_v1.03.
- `event_1.00`: generic event request/response/process layouts and dependencies from PL_010d_v1.03/Evento. These support alphanumeric CNPJ, access keys and event IDs, and four-digit statuses.
- `cad_2.00`: consulta cadastro request and answer (`consCad`, `retConsCad`) from PL_010d_v1.03/CadConsultaCadastro. The request is validated; answers are read by tag, since some states deviate from the schema's namespaces.
- `mdfe_3.00`: the MDF-e package PL_MDFe_300b_NT012025_1.05, whole: the manifest, the four modals, the events and the service messages. NT 2026.001 changed rules only.
- `PL_MDFeDistDFe_100`: the MDF-e distribution request and answer, NT 2015.002.
- `nfse_1.01`: the NFS-e package of 09/02/2026 (`nfse-esquemas_xsd-v1-01-20260209.zip`, folder `Schemas/1.01`), what the Sefin Nacional validates in production: the DPS, the NFS-e, the request to register an event, the event and the CNC.
- `nfse_1.01_nt009`: the produção restrita package of 20/10/2026 (`esquemas_prod_restrita_20261020.zip`), NT 009's layout, also numbered 1.01.
- `Evento_ManifestaDest_PL_v1.01`: unchanged official manifestation detail schemas (`e210200`, `e210210`, `e210220`, `e210240`). The manifestation client uses only these detail validators. Its envelope uses the generic event schemas above.

The NFS-e packages were copied unchanged from `dfe_law_reference/notes/docs/nfse/schemas`. The production package's `TSSerieDPS` pattern (`^0{0,4}\d{1,5}$`) has anchors libxml2 reads as characters; `Nfse::Layout` drops that one message and `Nfse::Validator` checks the series.

The NF-e packages were copied unchanged from the official material in `nfe-archiver-ruby/notes/nfe/schemas`, and the MDF-e ones from `dfe_law_reference/notes/mdfe_schemas`. NT 2020.001 v1.60 gives the current sequence and deadline rules where older schema annotations keep historical wording. Incoming documents are read by metadata readers that don't depend on the root or version, and a schema filename in a response is never used to open files or resources.
