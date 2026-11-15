require "time"

module DfeRb
  module Nfce
    # infNFeSupl, which an NFC-e and an NF-e printed as the DANFE Simplificado Tipo 2 carry
    # outside their signature (RV ZX02-10): the QR code (QrCode) and the address of the
    # consultation by key (urlChave), both of the issuer's state. The NF-e's are the NFC-e's
    # (RV ZX02-20, NT 2026.002; NT 2026.003 §4.3).
    module Supplement
      OFFLINE = QrCode::OFFLINE
      NFCE = "65"
      # tpImp of the DANFE Simplificado Tipo 2, an NF-e printed like an NFC-e (Ajuste SINIEF 13/26).
      SIMPLIFIED_TYPE_2 = "6"

      module_function

      # Whether a note with this ide carries infNFeSupl: an NFC-e, or an NF-e printed as the
      # DANFE Simplificado Tipo 2 (tpImp 6).
      def carried_by?(ide)
        ide ||= {}
        ide["mod"].to_s == NFCE || ide["tpImp"].to_s == SIMPLIFIED_TYPE_2
      end

      # [{"qrCode" => ..., "urlChave" => ...}, problems] for a resolved infNFe tree. Nil while
      # the key can't be built. An off-line note (tpEmis 9) signs its QR code, so it needs
      # the certificate; `overrides` are the client's endpoints (:qr_code, :consult_url).
      def build(tree, certificate: nil, overrides: {})
        id = tree["@Id"] or return [nil, []]
        ide = tree["ide"] || {}
        state = States.abbreviation(ide["cUF"])
        environment = Environment.normalize(ide["tpAmb"].to_s)
        key = id.delete_prefix("NFe")
        address = Endpoints.qr_code(uf: state, environment: environment, overrides: overrides)

        url = if ide["tpEmis"].to_s == OFFLINE
          unless certificate
            return [nil, ["infNFeSupl/qrCode: a note issued off-line signs its QR code with the certificate; " \
              "build it with client.build_invoice or pass certificate: (NT 2026.003 §4.3.2)"]]
          end
          QrCode.offline(address: address, key: key, environment: environment, issued_at: time(ide["dhEmi"]),
            total: tree.dig("total", "ICMSTot", "vNF"), recipient: tree["dest"], certificate: certificate)
        else
          QrCode.online(address: address, key: key, environment: environment)
        end
        [{"qrCode" => url, "urlChave" => Endpoints.consult_url(uf: state, environment: environment, overrides: overrides)}, []]
      end

      def time(value)
        return value.to_time if value.is_a?(DateTime)
        return value if value.respond_to?(:day)

        Time.iso8601(value.to_s)
      end
    end
  end
end
