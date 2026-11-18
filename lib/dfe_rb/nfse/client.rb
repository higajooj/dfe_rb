require "bigdecimal"

module DfeRb
  module Nfse
    # The entry point for issuing NFS-e through the Sistema Nacional NFS-e: the Sefin
    # Nacional's API, which takes a signed DPS and answers with the NFS-e, its events, and
    # the ADN's distribution and municipal parameters. All of it is JSON over mutual TLS.
    #
    #   client = DfeRb::Nfse::Client.new(certificate: cert, city: "5002704")   # homologação (produção restrita) by default
    #   dps = client.build_declaration { |d| ... }
    #   signed = client.sign(dps)            # store signed.xml before sending
    #   result = client.issue(signed)
    #   File.write(result.filename, result.nfse_xml) if result.issued?
    #   client.cancel(result.key, reason: "Servico nao prestado por desistencia do tomador", code: :not_rendered)
    class Client
      CONFIRMATIONS = {provider: "202201", taker: "203202", intermediary: "204203"}.freeze
      REJECTIONS = {provider: "202205", taker: "203206", intermediary: "204207"}.freeze
      CANCELLATION = "101101"
      CANCELLATION_REVIEW = "101103"
      CANCELLATION_REASONS = {error: 1, not_rendered: 2, other: 9}.freeze
      REJECTION_REASON_REQUIRED = {provider: "E1944", taker: "E1949", intermediary: "E1954"}.freeze
      REJECTION_REASONS = {duplicate: 1, issued_by_taker: 2, no_taxable_event: 3, tax_liability: 4, values: 5, other: 9}.freeze
      DUPLICATE = "E0014"
      DOCUMENT_KINDS = {"NFSE" => :nfse, "EVENTO" => :event, "DPS" => :dps, "PEDIDO_REGISTRO_EVENTO" => :event_request, "CNC" => :cnc}.freeze

      attr_reader :certificate, :environment, :layout, :city, :transport

      # certificate: a DfeRb::Certificate (ICP-Brasil, A1).
      # environment: :homologacao (default: produção restrita, no fiscal value) or :production.
      # city:        the issuer's municipality (cLocEmi of every DPS built here): an IBGE code
      #              or a [name, state] pair.
      # layout:      the DPS layout (Layouts): by default the one the environment validates.
      # endpoints:   host overrides, {sefin: "https://...", adn: "https://..."}.
      # transport:   anything with #request(method, url, body) returning a Transport::Reply.
      def initialize(certificate:, environment: Environment::HOMOLOGACAO, city: nil, layout: nil, endpoints: {}, transport: nil,
        timeouts: {}, logger: nil, clock: Time)
        @certificate = certificate
        @environment = Environment.normalize(environment)
        @city = city && Mdfe::Sugar.city(Array(city), {}).first
        @layout = layout ? Layouts.fetch(layout) : Layouts.default(@environment)
        @endpoints = endpoints
        @transport = transport || Transport.new(certificate: certificate, timeouts: timeouts, logger: logger)
        @clock = clock
      end

      def production? = environment == Environment::PRODUCTION

      # A new DPS for this client's environment, layout and city. Fill it with a block and/or a hash.
      def build_declaration(attributes = nil, **fields, &block)
        Declaration.new(attributes, environment: environment, layout: layout, clock: @clock, city: city, **fields, &block)
      end

      # Validates and signs a Declaration, or raw <DPS> XML (signed or not). Returns a
      # SignedDeclaration. Store its `xml` before sending, so a lost answer can be resolved later.
      #
      # Every input is checked against this client's layout. Raw XML also gets the business
      # rules a Declaration gets; a SignedDeclaration (or one restored from storage) isn't
      # checked against them again. Like any input it must be for this client's environment,
      # the certificate must belong to the DPS's issuer, and so must the certificate inside
      # a DPS signed elsewhere (E0718).
      #
      # `strict: false` skips the business-rule checks. The schema and value formats are always enforced.
      def sign(input, strict: true)
        if input.is_a?(Declaration) && input.layout != layout
          raise ValidationError, ["the declaration was built for the layout #{input.layout.name}, but this client sends #{layout.name}"]
        end

        document = case input
        when Declaration then Document.new(input.to_xml(strict: strict))
        when SignedDeclaration then Document.new(input.xml)
        else Document.new(input)
        end
        validate(document, rules: strict && !input.is_a?(Declaration) && !input.is_a?(SignedDeclaration))
        check_environment(document)
        check_certificate(document)

        signed = document.signed? ? document.xml : Signature.sign_dps(document.xml, certificate)
        problem = Signature.verify(signed, id: document.id)
        raise ValidationError, ["the signature does not verify: #{problem}"] unless problem == true

        result = SignedDeclaration.new(xml: signed, id: document.id, digest_value: Signature.digest_value(signed))
        (result == input) ? input : result
      end

      # Sends one DPS (POST /nfse); the Sefin answers in the same call with the NFS-e or the
      # reasons it refused. Accepts a Declaration, a SignedDeclaration or raw XML and returns
      # an IssueResult.
      #
      # When the answer is lost (a timeout, an HTTP 5xx) or the Sefin reports the series and
      # number as used (E0014), it looks the DPS up. If the note found carries this same DPS,
      # it returns that note (`result.recovered?` is true); if it carries another, it raises
      # Conflict.
      def issue(input, recover: true, strict: true)
        signed = sign(input, strict: strict)
        result = begin
          issue_result(signed, raise_if_server_failed(request(:post, :issue, body: {"dpsXmlGZipB64" => Requests.pack(signed.xml)})))
        rescue TransportError => e
          raise unless recover && e.maybe_processed?

          return look_up_issued_quietly(signed, e) || raise(e)
        end

        if recover && result.duplicate?
          found = begin
            look_up_issued(signed, cause: result)
          rescue TransportError => e
            raise TransportError.new("#{e.message}, looking the DPS up after #{result.code} #{result.message}",
              maybe_processed: e.maybe_processed?, http_status: e.http_status)
          end
          return found if found
        end
        check_note(signed, result.note, key: result.key) if result.issued?
        result
      end

      # Like #issue, but raises Rejected unless the NFS-e was generated.
      def issue!(input, **options)
        result = issue(input, **options)
        raise Rejected, result unless result.issued?

        result
      end

      # The NFS-e of `key` (GET /nfse/{key}), for its parties.
      def consult(key)
        key = access_key(key)
        reply = raise_if_server_failed(request(:get, :consult, key: key))
        xml = Requests.unpack(require_field(reply, "nfseXmlGZipB64")) if reply.success?
        ConsultResult.new(key: key, http_status: reply.status, errors: Message.list(reply.json, "erros", "erro"), nfse_xml: xml)
      end

      # The key of the NFS-e generated from a DPS (GET /dps/{id}): a SignedDeclaration, a
      # Declaration or the Id. Only the provider, the taker and the intermediary get it.
      def find(dps)
        id = dps_id(dps)
        reply = raise_if_server_failed(request(:get, :dps, id: id))
        key = require_field(reply, "chaveAcesso") if reply.success?
        LookupResult.new(id: id, key: key, http_status: reply.status, errors: Message.list(reply.json, "erros", "erro"))
      end

      # Whether an NFS-e was generated from a DPS (HEAD /dps/{id}), which anyone may ask.
      def issued?(dps)
        reply = request(:head, :dps, id: dps_id(dps))
        return true if reply.success?
        return false if reply.status == 404

        raise TransportError.new("HTTP #{reply.status} looking up the DPS", maybe_processed: false, http_status: reply.status)
      end

      # Cancels a note (event 101101). `code`: :error (1), :not_rendered (2) or :other (9).
      # The municipality sets until when a note can be canceled (E0822); after that, ask
      # for a fiscal review (#request_cancellation).
      def cancel(key, reason:, code: :error)
        detail = Requests.reason(code: reason_code(CANCELLATION_REASONS, code), text: justification(reason))
        send_event(key, CANCELLATION, detail)
      end

      # Asks the municipality to review the cancellation of a note it no longer lets the
      # issuer cancel (event 101103, Solicitação de Análise Fiscal para Cancelamento).
      def request_cancellation(key, reason:, code: :error)
        detail = Requests.reason(code: reason_code(CANCELLATION_REASONS, code), text: justification(reason))
        send_event(key, CANCELLATION_REVIEW, detail)
      end

      # Confirms the service, as the party of the note the certificate's holder is (events
      # 202201, 203202, 204203): `as: :provider`, `:taker` or `:intermediary`.
      def confirm(key, as: :taker)
        send_event(key, CONFIRMATIONS.fetch(as) { raise ArgumentError, "as: takes #{CONFIRMATIONS.keys.map(&:inspect).join(", ")}" }, "")
      end

      # Rejects the note, as one of its parties (events 202205, 203206, 204207). `code`:
      # :duplicate, :issued_by_taker, :no_taxable_event, :tax_liability, :values or :other,
      # which needs a `reason` (E1944, E1949, E1954).
      def reject(key, as: :taker, code: :other, reason: nil)
        type = REJECTIONS.fetch(as) { raise ArgumentError, "as: takes #{REJECTIONS.keys.map(&:inspect).join(", ")}" }
        number = reason_code(REJECTION_REASONS, code)
        if number == 9 && reason.nil?
          raise ArgumentError, "a rejection for another reason (:other) says why: give reason: (#{REJECTION_REASON_REQUIRED.fetch(as)})"
        end

        send_event(key, type, Requests.reason(code: number, text: reason && justification(reason)))
      end

      # An event registered for a note (GET /nfse/{key}/eventos/{type}/{sequence}).
      def event(key, type:, sequence: 1)
        key = access_key(key)
        reply = raise_if_server_failed(request(:get, :event_query, key: key, type: type, sequence: sequence))
        event_result(key, type.to_s, reply, nil)
      end

      # Every event of a note the ADN holds (GET /contribuintes/NFSe/{key}/Eventos): a
      # DistributionBatch whose documents are the events.
      def events(key)
        batch(raise_if_server_failed(request(:get, :events, key: access_key(key))))
      end

      # The NFS-e and events of interest to a taxpayer after `after` (an NSU, exclusive),
      # from the ADN (GET /contribuintes/DFe/{NSU}). The taxpayer is the certificate's holder
      # unless `cnpj:` names another establishment of the same CNPJ root, or someone who
      # granted a proxy (procuração); `cpf:` likewise. `batch: false` brings one document.
      #
      # The holder is always named: asked without cnpjConsulta, produção restrita answers
      # REJEICAO with no error (seen on 18/11/2026).
      def distribute(after: 0, cnpj: nil, cpf: nil, batch: true)
        raise ArgumentError, "give cnpj: or cpf:, not both (E2244)" if cnpj && cpf

        cnpj ||= certificate.cnpj unless cpf
        cpf ||= certificate.cpf unless cnpj
        query = {"lote" => batch}
        query["cnpjConsulta"] = TaxId.normalize(cnpj) if cnpj
        query["cpfConsulta"] = TaxId.normalize(cpf) if cpf
        batch(raise_if_server_failed(request(:get, :distribution, query: query, nsu: Integer(after))))
      end

      # A municipality's agreement with the Sistema Nacional (parametrização, convênio):
      # whether its taxpayers issue through the Sefin Nacional. `city` is an IBGE code or a
      # [name, state] pair.
      def agreement(city = self.city)
        code = city_code(city)
        json = raise_if_server_failed(request(:get, :agreement, city: code)).json
        parameters = json["parametrosConvenio"] || {}
        Agreement.new(
          city: code, found: !json["parametrosConvenio"].nil?, national_data: parameters["aderenteAmbienteNacional"],
          national_issuer: parameters["aderenteEmissorNacional"], rfb_standard_issue: parameters["situacaoEmissaoPadraoContribuintesRFB"],
          man: parameters["aderenteMAN"], credit_allowed: parameters["permiteAproveitametoDeCreditos"], message: json["mensagem"]
        )
      end

      # The ISSQN rates `city` set for a service (cTribNac, "010101", and the municipal code,
      # "000" by default) on a competence (parametrização, aliquota).
      def rates(city = self.city, service:, municipal_code: "000", on: Date.today)
        code = city_code(city)
        national = service.to_s.delete("^0-9")
        raise ArgumentError, "service is the 6-digit national code (cTribNac), got #{service.inspect}" unless national.match?(/\A\d{6}\z/)

        formatted = "#{national.scan(/../).join(".")}.#{municipal_code}"
        json = raise_if_server_failed(request(:get, :rates, city: code, code: formatted, date: on.strftime("%Y-%m-%d"))).json
        listed = (json["aliquotas"] || {}).values.flatten.map do |entry|
          Rate.new(incidence: entry["Incidencia"], rate: entry["Aliq"] && BigDecimal(entry["Aliq"].to_s),
            starts_on: entry["DtIni"] && Date.parse(entry["DtIni"]), ends_on: entry["DtFim"] && Date.parse(entry["DtFim"]))
        end
        RatesResult.new(city: code, service: formatted, rates: listed, message: json["mensagem"])
      end

      # Sends a request as is and returns the Transport::Reply. `service` is one of
      # Endpoints::SERVICES, its path parameters given as keywords.
      def raw(method, service, body: nil, query: nil, **params) = request(method, service, body: body, query: query, **params)

      def url(service, **params) = Endpoints.url(environment: environment, service: service, overrides: @endpoints, **params)

      private

      def request(method, service, body: nil, query: nil, **params)
        address = url(service, **params)
        address += "?#{URI.encode_www_form(query)}" if query && !query.empty?
        transport.request(method, address, body)
      end

      def raise_if_server_failed(reply)
        return reply unless reply.status >= 500

        detail = Message.list(reply.json, "erros", "erro", "Erros").join("; ")
        raise TransportError.new("HTTP #{reply.status} from the Sistema Nacional NFS-e#{": #{detail}" unless detail.empty?}",
          maybe_processed: true, http_status: reply.status)
      end

      def issue_result(signed, reply, recovered: false)
        json = reply.json || {}
        xml = Requests.unpack(require_field(reply, "nfseXmlGZipB64")) if reply.success?
        IssueResult.new(
          id: json["idDps"] || json["idDPS"] || signed.id, key: json["chaveAcesso"], http_status: reply.status,
          processed_at: json["dataHoraProcessamento"], alerts: Message.list(json, "alertas"), errors: Message.list(json, "erros", "erro"),
          signed_xml: signed.xml, nfse_xml: xml, recovered: recovered
        )
      end

      def check_note(signed, note, key:)
        unless note.key == key
          raise Conflict, "the Sefin answered about #{key}, but the NFS-e it sent is #{note.key}"
        end
        unless note.dps_id == signed.id
          raise Conflict, "the NFS-e #{note.key} is of #{note.dps_id}, not of #{signed.id}, the DPS sent"
        end
        digest = note.dps_digest(Signature.digest_algorithm(signed.xml))
        return if digest == signed.digest_value

        raise Conflict, "the NFS-e #{note.key} carries another DPS than the one sent (digest #{digest.inspect}, not #{signed.digest_value})"
      end

      def require_field(reply, field)
        value = reply.json&.[](field)
        return value if value.is_a?(String) && !value.empty?

        raise TransportError.new("HTTP #{reply.status} without #{field} in the answer", maybe_processed: true, http_status: reply.status)
      end

      def batch(reply)
        json = reply.json || {}
        DistributionBatch.new(
          status: json["StatusProcessamento"], documents: documents(json), alerts: Message.list(json, "Alertas"),
          errors: Message.list(json, "Erros"), http_status: reply.status, query: json["TipoConsulta"]
        )
      end

      def look_up_issued_quietly(signed, cause)
        look_up_issued(signed, cause: cause)
      rescue TransportError
        nil
      end

      def look_up_issued(signed, cause:)
        found = find(signed)
        return unless found.found?

        consulted = consult(found.key)
        return unless consulted.found?

        note = consulted.note
        begin
          check_note(signed, note, key: found.key)
        rescue Conflict => e
          raise Conflict, "the Sefin already holds #{found.key} for #{signed.id}, but not this DPS: #{e.message} " \
            "(#{cause.respond_to?(:message) ? cause.message : cause})"
        end

        IssueResult.new(id: signed.id, key: note.key, http_status: consulted.http_status, processed_at: note.processed_at,
          alerts: [], errors: [], signed_xml: signed.xml, nfse_xml: consulted.nfse_xml, recovered: true)
      end

      def send_event(key, type, detail)
        key = access_key(key)
        unsigned = Requests.event(key: key, type: type, author: certificate.tax_id, detail: detail, environment: environment,
          at: Nfse.local_time(key[0, 7], @clock), version: layout.version)
        signed = Signature.sign_event(unsigned, certificate)
        problems = layout.event_issues(signed)
        raise ValidationError, problems unless problems.empty?

        reply = raise_if_server_failed(request(:post, :event, key: key, body: {"pedidoRegistroEventoXmlGZipB64" => Requests.pack(signed)}))
        event_result(key, type, reply, signed)
      end

      def event_result(key, type, reply, signed)
        xml = Requests.unpack(require_field(reply, "eventoXmlGZipB64")) if reply.success?
        EventResult.new(key: key, type: type, http_status: reply.status, errors: Message.list(reply.json, "erros", "erro"),
          request_xml: signed, event_xml: xml)
      end

      def documents(json)
        Array(json&.[]("LoteDFe")).map do |entry|
          DistributedDocument.new(
            nsu: entry["NSU"], key: entry["ChaveAcesso"], kind: DOCUMENT_KINDS.fetch(entry["TipoDocumento"].to_s, entry["TipoDocumento"]),
            event_type: entry["TipoEvento"], xml: entry["ArquivoXml"] && Requests.unpack(entry["ArquivoXml"]),
            generated_at: entry["DataHoraGeracao"]
          )
        end
      end

      def validate(document, rules:)
        problems = layout.dps_issues(document.xml)
        problems += Validator.new(document.to_infdps(layout), layout: layout).issues if rules && problems.empty?
        raise ValidationError, problems unless problems.empty?
      end

      def check_environment(document)
        declared = document.environment
        return if declared.nil? || declared == Environment.code(environment)

        raise ValidationError, ["the DPS was built for #{(declared == "1") ? "production" : "homologacao"} " \
          "but this client talks to #{environment} (E0006)"]
      end

      def check_certificate(document)
        now = @clock.now
        problems = []
        problems << "the certificate expired on #{certificate.expires_at.utc.iso8601}" if certificate.expired?(now)
        problems << "the certificate is not valid yet (starts #{certificate.not_before.utc.iso8601})" if certificate.not_before > now

        problems << owner_problem("the certificate", certificate.cnpj, certificate.cpf, document)
        if document.signed? && (signer = document.signer)
          id = Certificate.tax_id_of(signer).to_s
          problems << owner_problem("the DPS's signature", (id if id.length == 14), (id if id.length == 11), document)
        end
        problems.compact!
        raise ValidationError, problems unless problems.empty?
      end

      def owner_problem(what, holder_cnpj, holder_cpf, document)
        cnpj = document.issuer_cnpj
        cpf = document.issuer_cpf
        holder = holder_cnpj ? "CNPJ root #{holder_cnpj[0, 8]}" : ("CPF #{holder_cpf}" if holder_cpf)
        return if holder.nil?

        mismatch = (cnpj && cnpj[0, 8] != holder_cnpj.to_s[0, 8]) || (cpf && cpf != holder_cpf)
        "#{what} belongs to #{holder} but the DPS's issuer is #{cnpj || cpf} (E0718)" if mismatch
      end

      def access_key(key)
        value = key.to_s.strip.upcase
        raise ArgumentError, "an NFS-e access key has 50 characters, got #{value.inspect}" unless value.match?(/\A[0-9]{9}[0-9A-Z]{14}[0-9]{27}\z/)

        value
      end

      def dps_id(dps)
        id = case dps
        when SignedDeclaration then dps.id
        when Declaration then dps.id
        else dps.to_s.strip
        end
        raise ArgumentError, "a DPS Id is \"DPS\" and 42 characters, got #{id.inspect}" unless id.to_s.match?(/\ADPS[0-9]{8}[0-9A-Z]{14}[0-9]{20}\z/)

        id
      end

      def city_code(city)
        code = Mdfe::Sugar.city(Array(city), {}).first if city
        code or raise ArgumentError, "give the municipality: an IBGE code, or its name and state"
      end

      def reason_code(table, code)
        return code if table.value?(code)

        table.fetch(code) { raise ArgumentError, "unknown code #{code.inspect} (use #{table.keys.map(&:inspect).join(", ")})" }
      end

      def justification(text)
        clean = Formatter.sanitize(text)
        raise ArgumentError, "reason must have 15 to 255 characters (got #{clean.length})" unless (15..255).cover?(clean.length)

        clean
      end
    end
  end
end
