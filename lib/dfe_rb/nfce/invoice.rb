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

      def initialize(attributes = nil, certificate: nil, endpoints: {}, **options, &block)
        @certificate = certificate
        @addresses = endpoints
        super(attributes, **options, &block)
      end

      # infNFeSupl/qrCode: the URL the DANFE NFC-e's QR code holds. Nil while the key can't
      # be built, or off-line without a certificate to sign it.
      def qr_code = supplement_of(resolved).first&.fetch("qrCode")

      # infNFeSupl/urlChave: where the consumer looks the note up by its key.
      def consult_url = supplement_of(resolved).first&.fetch("urlChave")

      private

      def supplement_of(tree) = Supplement.build(tree, certificate: @certificate, overrides: @addresses)

      def rule_issues(tree, supplement)
        super + Validator.new(tree, supplement: supplement, signer: @certificate&.certificate).issues
      end
    end
  end
end
