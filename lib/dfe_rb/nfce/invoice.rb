module DfeRb
  module Nfce
    # An NFC-e being put together: an Nfe::Invoice of modelo 65, with the same builder.
    #
    #   invoice = client.build_invoice do |nfce|
    #     nfce.number 1
    #     nfce.nature_of_operation "Venda"
    #     nfce.issuer cnpj: "...", name: "...", state_registration: "...", tax_regime: :simples, address: {...}
    #     nfce.consumer cpf: "...", name: "..."   # optional
    #     nfce.item { |i| i.description "Cafe"; i.cfop "5102"; i.quantity 1; i.unit_price "8.50"; ... }
    #     nfce.payment :pix, card: {integration: :not_integrated}
    #   end
    #   invoice.to_xml   # => the unsigned <NFe>, with infNFeSupl
    #   invoice.qr_code  # => what the DANFE NFC-e's QR code holds
    #
    # Besides the NF-e's defaults (see Nfe::Resolver), an NFC-e is a final consumer's
    # in-person, internal sale (indFinal 1, indPres 1, idDest 1, indIEDest 9), printed as the
    # DANFE NFC-e (tpImp 4); in homologação its first item is described as RV I04-10 requires.
    #
    # `certificate:` is needed only by a note issued off-line (contingency :offline), whose QR
    # code is signed with it. Client#build_invoice passes its own. `endpoints:` may override
    # the state's QR code and consultation addresses (:qr_code, :consult_url).
    class Invoice < Nfe::Invoice
      MODEL = 65

      private

      # The NFC-e's rules hold for modelo 65; a note forced to another model is told so.
      def rule_issues(tree, supplement)
        return super if tree.dig("ide", "mod").to_s == Supplement::NFCE

        super + ["ide/mod: an NFC-e is modelo 65 (DfeRb::Nfe issues modelo 55)"]
      end
    end
  end
end
