require "base64"
require "openssl"

module DfeRb
  module Nfce
    # The URL in infNFeSupl/qrCode, which is also what the DANFE NFC-e's QR code holds, in
    # version 3 (NT 2025.001 §04; the parameters as NT 2026.003 §4.3 tabulates them). It needs
    # no CSC: a note issued on-line carries its key, the version and tpAmb; one issued off-line
    # (tpEmis 9) adds the day of issue, vNF and the recipient's identification, and signs
    # those seven parameters with the certificate that signs the note (RSA-SHA1, Base64).
    #
    # The signature goes into the URL as the standard Base64 string it is, with its `+`, `/`
    # and `=` as they are, never percent-encoded and never Base64URL: NT 2026.003 §4.3.2
    # (Tabela 2, 8th parameter: "RSA SHA-1 (Base64)") and its model URL for a note issued
    # off-line print one with all three characters (`...gVfC2Hw+Lsno...`, `.../fUHJy3...`,
    # `...zvo=`), and NT 2025.001 §04 gives the parameter as `<assinatura>`. Neither text
    # says anything about escaping, so the gem writes what the NT's own example shows and
    # the printed QR code is what SEFAZ's page has to read; whether a state's consultation
    # page decodes a `+` as one is for homologação to confirm (issue #4). `parse` and
    # `signed_by?` accept a signature that went through a URL encoder, as one scanned and
    # re-opened by an app may have.
    module QrCode
      VERSION = "3"
      OFFLINE = "9"
      # tp_idDest: the kind of recipient identification.
      RECIPIENT_KINDS = {"CNPJ" => "1", "CPF" => "2", "idEstrangeiro" => "3"}.freeze

      module_function

      # The URL for a note issued on-line. `address` is the state's consultation page
      # (Endpoints.qr_code).
      def online(address:, key:, environment:)
        "#{address}?p=#{key}|#{VERSION}|#{Environment.code(environment)}"
      end

      # The URL for a note issued off-line. `recipient` is {"CNPJ" => ...}, {"CPF" => ...} or
      # {"idEstrangeiro" => ...} (dest), or nil for an unidentified consumer; a foreign one
      # goes without its id (NT 2026.003 table 2, 7th parameter).
      def offline(address:, key:, environment:, issued_at:, total:, recipient:, certificate:)
        content = offline_content(key: key, environment: environment, issued_at: issued_at, total: total, recipient: recipient)
        "#{address}?p=#{content}|#{signature(content, certificate)}"
      end

      # Parameters 1 to 7 of an off-line QR code, which its signature covers.
      def offline_content(key:, environment:, issued_at:, total:, recipient:)
        kind, id = identification(recipient)
        [key, VERSION, Environment.code(environment), format("%02d", issued_at.day), amount(total), kind, id].join("|")
      end

      def signature(content, certificate)
        Base64.strict_encode64(certificate.private_key.sign(OpenSSL::Digest.new("SHA1"), content))
      end

      # Whether `sign` is `content` signed by the holder of `x509`, an OpenSSL certificate.
      # `sign` may be as `signature` writes it or as a URL encoder left it (see
      # `normalize_signature`).
      def signed_by?(content, sign, x509)
        x509.public_key.verify(OpenSSL::Digest.new("SHA1"), Base64.strict_decode64(normalize_signature(sign)), content.to_s)
      rescue OpenSSL::PKey::PKeyError, ArgumentError
        false
      end

      # A signature read back from a URL as standard, padded Base64. The gem writes it raw, but
      # a note's QR code may have been through something that percent-encoded it (`%2B`, `%2F`,
      # `%3D`), read `+` as a space (form decoding) or used the URL-safe alphabet (`-` and `_`,
      # no padding). None of those are Base64 characters otherwise, so each is taken back.
      def normalize_signature(sign)
        text = sign.to_s.gsub(/%(\h\h)/) { [$1].pack("H2") }.tr(" ", "+").tr("-_", "+/")
        text.ljust((text.size + 3) / 4 * 4, "=")
      end

      # [tp_idDest, idDest] of a recipient: both empty when there is none.
      def identification(recipient)
        tag = RECIPIENT_KINDS.keys.find { |name| recipient&.key?(name) } or return ["", ""]

        [RECIPIENT_KINDS[tag], (tag == "idEstrangeiro") ? "" : recipient[tag].to_s]
      end

      # vNF as the schema writes it: "60.90", no thousands separator.
      def amount(value) = format("%.2f", BigDecimal(value.to_s))

      # The parts of a QR code URL: {address:, key:, version:, environment:, and, off-line,
      # day:, total:, recipient_kind:, recipient_id:, signature:, signed_content:}. Nil when it
      # isn't one ("<address>?p=<parameters>"). The signature is standard Base64 whichever
      # way the URL wrote it (see `normalize_signature`); `parameters` keeps the text as read.
      def parse(url)
        address, parameters = url.to_s.split("?p=", 2)
        return unless address && parameters

        values = parameters.split("|", -1)
        parsed = {address: address, key: values[0], version: values[1], environment: values[2], parameters: values}
        if values.size >= 8 && values[1] == VERSION
          parsed.merge!(day: values[3], total: values[4], recipient_kind: values[5], recipient_id: values[6],
            signature: normalize_signature(values[7]), signed_content: values[0, 7].join("|"))
        end
        parsed
      end
    end
  end
end
