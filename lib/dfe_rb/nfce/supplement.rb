require "time"

module DfeRb
  module Nfce
    # infNFeSupl, which an NFC-e carries outside its signature (RV ZX02-10): the QR code
    # (QrCode) and the address of the consultation by key (urlChave), both of the issuer's
    # state.
    module Supplement
      OFFLINE = QrCode::OFFLINE

      module_function

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
            return [nil, ["infNFeSupl/qrCode: an NFC-e issued off-line signs its QR code with the certificate; " \
              "build it with client.build_invoice or pass certificate: (NT 2025.001)"]]
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
