module DfeRb
  module Nfce
    # The entry point for issuing NFC-e with a certificate. It is the NF-e client
    # (Nfe::Client) with the NFC-e's authorizers, rules and QR code:
    #
    #   client = DfeRb::Nfce::Client.new(certificate: cert, uf: "MS")   # homologação by default
    #   client.status.online?
    #   signed = client.sign(invoice)          # store signed.xml before sending
    #   result = client.authorize(signed)      # one note, answered synchronously
    #   File.write(result.filename, result.proc_xml) if result.authorized?
    #
    # What differs from the NF-e: one note per request (RV GAP03a-4), no SVC (B22-70: issue
    # off-line instead), no carta de correção (rej. 784), no EPEC, a cancellation within 30
    # minutes of the authorization unless the state allows longer, and the cancellation by
    # substitution of a note an off-line one replaced.
    class Client < Nfe::Client
      MODEL = 65
      MAX_LOT = 1
      CANCEL_BY_SUBSTITUTION = "110112"
      NORMAL = 1
      OFFLINE = 9
      NO_SVC = "the SVC doesn't authorize NFC-e (rej. 783); while the state's authorizer is down, issue the note off-line " \
        "(contingency :offline) and authorize it once it is back"

      # Like Nfe::Client.new. `endpoints:` also takes :qr_code and :consult_url, the state's
      # addresses the QR code and urlChave point to.

      # A new NFC-e for this client's environment, signed with its certificate when off-line.
      def build_invoice(attributes = nil, **fields, &block)
        Invoice.new(attributes, environment: environment, clock: @clock, technical_contact: @technical_contact,
          certificate: certificate, endpoints: @endpoints, **fields, &block)
      end

      # Asks whether the state's NFC-e authorizer is up (cStat 107).
      def status(uf: self.uf, contingency: false)
        raise Unsupported, NO_SVC if contingency

        super(uf: uf)
      end

      # Sends one NFC-e, synchronously (indSinc 1), and returns its AuthorizationResult; an
      # Array of one note returns an Array. A lot holds a single NFC-e (RV GAP03a-4, rej. 126).
      # A lost answer or a duplicate is resolved by key, as Nfe::Client#authorize does.
      def authorize(input, lot_id: nil, recover: true, polling: {}, strict: true)
        notes = Array(input)
        if notes.size > MAX_LOT
          raise ArgumentError, "an NFC-e lot holds a single note (rej. 126); authorize each one in its own call"
        end

        super
      end

      def correct(*, **)
        raise Unsupported, "an NFC-e takes no carta de correção (rej. 784); cancel it and issue another"
      end

      def epec(*) = raise(Unsupported, "dfe_rb doesn't send the NFC-e's EPEC; issue the note off-line (contingency :offline)")

      def prepare_epec(*) = epec

      # Cancels a note issued normally that an off-line one (tpEmis 9) replaced for the same
      # sale, when both were authorized (evento 110112, NT 2018.004): within 168 hours, with
      # the same total, ICMS, consumer and items, issued up to 2 hours apart. `protocol` is the
      # canceled note's authorization protocol and `replacement` the key of the off-line one.
      def cancel_by_substitution(key, protocol:, replacement:, reason:)
        key = AccessKey.parse(key.to_s)
        replacement = AccessKey.parse(replacement.to_s)
        protocol = protocol.to_s.strip
        raise ArgumentError, "protocol must have 15 or 17 digits" unless protocol.match?(/\A(\d{15}|\d{17})\z/)

        problems = substitution_problems(key, replacement)
        raise ArgumentError, problems.join("; ") unless problems.empty?

        detail = Requests.substitution_detail(state: key.state, protocol: protocol, replacement: replacement,
          reason: justification(reason, "reason", 15..255))
        send_event(key, CANCEL_BY_SUBSTITUTION, 1, detail)
      end

      def endpoint(service, uf: self.uf, contingency: false)
        raise Unsupported, NO_SVC if contingency

        Endpoints.resolve(uf: uf, environment: environment, service: service, overrides: @endpoints)
      end

      private

      # An NFC-e handed in as XML gets the NFC-e's rules too, and a signed one must carry its
      # QR code (RV ZX02-10), which no one may add after the signature.
      def validated(document, strict:)
        super
        supplement = document.supplement
        if document.signed? && supplement.nil?
          raise ValidationError, ["infNFeSupl: a signed NFC-e carries its QR code (rej. 394); it can't be added after signing"]
        end
        return document unless strict

        problems = Validator.new(document.to_infnfe, supplement: supplement, signer: document.signer || certificate.certificate).issues
        raise ValidationError, problems unless problems.empty?

        document
      end

      # An unsigned NFC-e handed in without infNFeSupl gets it: the QR code and urlChave of
      # its state, signed with this client's certificate when issued off-line.
      def supplemented(document)
        return document if document.supplement

        supplement, problems = Supplement.build(document.to_infnfe, certificate: certificate, overrides: @endpoints)
        raise ValidationError, problems unless problems.empty?
        raise ValidationError, ["infNFe/@Id: the note has no access key to build its QR code from"] unless supplement

        supplied = document.with_supplement(supplement)
        problems = Nfe::Schemas.nfe_issues(supplied.xml)
        raise ValidationError, problems unless problems.empty?

        supplied
      end

      def substitution_problems(key, replacement)
        problems = []
        problems << "the replacement is the canceled note itself (rej. 911)" if key == replacement
        unless [key.state_code, key.tax_id, key.model] == [replacement.state_code, replacement.tax_id, replacement.model]
          problems << "the replacement is a note of the same state, issuer and model (rej. 911)"
        end
        problems << "only a note issued normally (tpEmis 1) is canceled by substitution (rej. 920)" unless key.emission_type == NORMAL
        unless replacement.emission_type == OFFLINE
          problems << "the replacement is the note issued off-line (tpEmis 9) for the same sale (rej. 920)"
        end
        problems
      end
    end
  end
end
