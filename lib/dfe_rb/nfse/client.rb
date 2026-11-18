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
      REJECTION_REASONS = {duplicate: 1, issued_by_taker: 2, no_taxable_event: 3, tax_liability: 4, values: 5, other: 9}.freeze
      # The DPS's series and number already produced a note (E0014).
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
      # Raw XML gets the same schema and business-rule checks as a Declaration, against this
      # client's layout. Like any input it must be for this client's environment, and the
      # certificate must belong to the DPS's issuer (E0718).
      #
      # `strict: false` skips the business-rule checks. The schema and value formats are always enforced.
      def sign(input, strict: true)
        document = case input
        when Declaration then Document.new(input.to_xml(strict: strict))
        when SignedDeclaration then Document.new(input.xml)
        else validated(Document.new(input), strict: strict)
        end
        check_environment(document)
        check_certificate(document)

        signed = document.signed? ? document.xml : Signature.sign_dps(document.xml, certificate)
        problem = Signature.verify(signed)
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
        reply = begin
          answered(request(:post, :issue, body: {"dpsXmlGZipB64" => Requests.pack(signed.xml)}))
        rescue TransportError => e
          raise unless recover && e.maybe_processed?

          # If the lookup fails too, the first error stands.
          return recovered_quietly(signed, e) || raise(e)
        end

        result = issue_result(signed, reply)
        if recover && result.duplicate?
          found = recovered(signed, cause: result)
          return found if found
        end
        check_note(signed, result) if result.issued?
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
        reply = answered(request(:get, :consult, key: key))
        xml = Requests.unpack(reply.json["nfseXmlGZipB64"]) if reply.success? && reply.json["nfseXmlGZipB64"]
        ConsultResult.new(key: key, http_status: reply.status, errors: Message.list(reply.json, "erros", "erro"), nfse_xml: xml)
      end

      # The key of the NFS-e generated from a DPS (GET /dps/{id}): a SignedDeclaration, a
      # Declaration or the Id. Only the provider, the taker and the intermediary get it.
      def find(dps)
        id = dps_id(dps)
        reply = answered(request(:get, :dps, id: id))
        key = reply.json["chaveAcesso"] if reply.success?
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
      # which needs a `reason` (E1944).
      def reject(key, as: :taker, code: :other, reason: nil)
        type = REJECTIONS.fetch(as) { raise ArgumentError, "as: takes #{REJECTIONS.keys.map(&:inspect).join(", ")}" }
        number = reason_code(REJECTION_REASONS, code)
        raise ArgumentError, "a rejection for another reason (:other) says why: give reason: (E1944)" if number == 9 && reason.nil?

        send_event(key, type, Requests.reason(code: number, text: reason && justification(reason)))
      end

      # An event registered for a note (GET /nfse/{key}/eventos/{type}/{sequence}).
      def event(key, type:, sequence: 1)
        key = access_key(key)
        reply = answered(request(:get, :event_query, key: key, type: type, sequence: sequence))
        event_result(key, type.to_s, reply, nil)
      end

      # Every event of a note the ADN holds (GET /contribuintes/NFSe/{key}/Eventos), as
      # DistributedDocuments.
      def events(key)
        reply = answered(request(:get, :events, key: access_key(key)))
        documents(reply.json)
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
        reply = answered(request(:get, :distribution, query: query, nsu: Integer(after)))
        json = reply.json
        DistributionBatch.new(
          status: json["StatusProcessamento"], documents: documents(json), alerts: Message.list(json, "Alertas"),
          errors: Message.list(json, "Erros"), http_status: reply.status, query: json["TipoConsulta"]
        )
      end

      # A municipality's agreement with the Sistema Nacional (parametrização, convênio):
      # whether its taxpayers issue through the Sefin Nacional. `city` is an IBGE code or a
      # [name, state] pair.
      def agreement(city = self.city)
        code = city_code(city)
        json = answered(request(:get, :agreement, city: code)).json
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
        json = answered(request(:get, :rates, city: code, code: formatted, date: on.strftime("%Y-%m-%d"))).json
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

      # The reply, unless it is a server failure: a 5xx is an answer that may hide a processed
      # request, so it is a TransportError the issue recovers from.
      def answered(reply)
        return reply unless reply.status >= 500

        detail = Message.list(reply.json, "erros", "erro", "Erros").join("; ")
        raise TransportError.new("HTTP #{reply.status} from the Sistema Nacional NFS-e#{": #{detail}" unless detail.empty?}",
          maybe_processed: true, http_status: reply.status)
      end

      def issue_result(signed, reply, recovered: false)
        json = reply.json || {}
        xml = Requests.unpack(json["nfseXmlGZipB64"]) if reply.success? && json["nfseXmlGZipB64"]
        IssueResult.new(
          id: json["idDps"] || json["idDPS"] || signed.id, key: json["chaveAcesso"], http_status: reply.status,
          processed_at: json["dataHoraProcessamento"], alerts: Message.list(json, "alertas"), errors: Message.list(json, "erros", "erro"),
          signed_xml: signed.xml, nfse_xml: xml, recovered: recovered
        )
      end

      # The note must carry the very DPS sent.
      def check_note(signed, result)
        note = result.note
        unless note.dps_id == signed.id
          raise Conflict, "the Sefin answered with the NFS-e of #{note.dps_id}, not of #{signed.id}, the DPS sent; look it up with find"
        end
        return if note.dps_digest_value.nil? || note.dps_digest_value == signed.digest_value

        raise Conflict, "the NFS-e #{note.key} carries a DPS whose digest is #{note.dps_digest_value}, not #{signed.digest_value}, the DPS sent"
      end

      def recovered_quietly(signed, cause)
        recovered(signed, cause: cause)
      rescue TransportError
        nil
      end

      # Looks the DPS up after a lost answer or a duplicate report. Returns the result when
      # the Sefin holds a note of this very DPS, nil when it holds none (safe to send again),
      # and raises Conflict when the note carries another DPS.
      def recovered(signed, cause:)
        found = find(signed)
        return unless found.found?

        consulted = consult(found.key)
        return unless consulted.found?

        note = consulted.note
        unless note.dps_digest_value == signed.digest_value
          raise Conflict, "the Sefin already holds #{note.key} for #{signed.id} with another DPS inside; " \
            "the DPS being sent differs from the one stored (#{cause.respond_to?(:message) ? cause.message : cause})"
        end

        IssueResult.new(id: signed.id, key: note.key, http_status: consulted.http_status, processed_at: note.processed_at,
          alerts: [], errors: [], signed_xml: signed.xml, nfse_xml: consulted.nfse_xml, recovered: true)
      end

      def send_event(key, type, detail)
        key = access_key(key)
        unsigned = Requests.event(key: key, type: type, author: certificate.tax_id, detail: detail, environment: environment,
          at: event_time(key), version: layout.version)
        signed = Signature.sign_event(unsigned, certificate)
        problems = layout.event_issues(signed)
        raise ValidationError, problems unless problems.empty?

        reply = answered(request(:post, :event, key: key, body: {"pedidoRegistroEventoXmlGZipB64" => Requests.pack(signed)}))
        event_result(key, type, reply, signed)
      end

      def event_result(key, type, reply, signed)
        xml = Requests.unpack(reply.json["eventoXmlGZipB64"]) if reply.success? && reply.json["eventoXmlGZipB64"]
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

      # The event's time in the offset of the state of the note's issuing city.
      def event_time(key)
        state = States::CODES.key(key[0, 2].to_i)
        state ? States.now(state, @clock) : @clock.now.getlocal(States::DEFAULT_UTC_OFFSET)
      end

      def validated(document, strict:)
        problems = layout.dps_issues(document.xml)
        problems += Validator.new(document.to_infdps(layout), layout: layout).issues if strict && problems.empty?
        raise ValidationError, problems unless problems.empty?

        document
      end

      def check_environment(document)
        declared = document.environment
        return if declared.nil? || declared == Environment.code(environment)

        raise ValidationError, ["the DPS was built for #{(declared == "1") ? "production" : "homologacao"} " \
          "but this client talks to #{environment} (E0006)"]
      end

      # The certificate must be valid and belong to the DPS's issuer: the same CNPJ root, or
      # the same CPF (E0718). One that names no one is left for the Sefin to judge.
      def check_certificate(document)
        now = @clock.now
        problems = []
        problems << "the certificate expired on #{certificate.expires_at.utc.iso8601}" if certificate.expired?(now)
        problems << "the certificate is not valid yet (starts #{certificate.not_before.utc.iso8601})" if certificate.not_before > now

        cnpj = document.issuer_cnpj
        cpf = document.issuer_cpf
        holder = certificate.cnpj ? "CNPJ root #{certificate.cnpj_root}" : ("CPF #{certificate.cpf}" if certificate.cpf)
        if holder && ((cnpj && cnpj[0, 8] != certificate.cnpj_root) || (cpf && cpf != certificate.cpf))
          problems << "the certificate belongs to #{holder} but the DPS's issuer is #{cnpj || cpf} (E0718)"
        end
        raise ValidationError, problems unless problems.empty?
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
