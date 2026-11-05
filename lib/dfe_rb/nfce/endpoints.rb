module DfeRb
  module Nfce
    # Where each NFC-e web service lives, and the addresses an NFC-e prints for the consumer.
    #
    # The NFC-e has its own authorizers, at other addresses than the NF-e's, though the
    # services, their WSDL names and their messages are the NF-e's (Nfe::Endpoints::SERVICES).
    # URLs come from the SVRS DF-e portal's "Relação de Serviços Web" (dfe-portal.svrs.rs.gov.br/
    # Nfce/Servicos); MG, missing there, answers at its own (checked live). Every URL can be
    # overridden per client with `endpoints:`, so a moved one doesn't block you.
    module Endpoints
      Endpoint = Nfe::Endpoints::Endpoint
      SERVICES = Nfe::Endpoints::SERVICES
      SERVICE_KEYS = Nfe::Endpoints::SERVICE_KEYS

      # Path of each service under an authorizer's base URL: the NF-e's families, and SP's
      # NFC-e, which capitalizes its files.
      PATHS = Nfe::Endpoints::PATHS.merge(
        sp_nfce: {
          status: "NFeStatusServico4.asmx", authorization: "NFeAutorizacao4.asmx",
          authorization_return: "NFeRetAutorizacao4.asmx", consult: "NFeConsultaProtocolo4.asmx",
          inutilization: "NFeInutilizacao4.asmx", event: "NFeRecepcaoEvento4.asmx"
        }
      ).freeze

      # authorizer => [paths family, production base, homologação base]
      AUTHORIZERS = {
        "AM" => [:am_mt, "https://nfce.sefaz.am.gov.br/nfce-services/services/", "https://homnfce.sefaz.am.gov.br/nfce-services/services/"],
        "GO" => [:java, "https://nfe.sefaz.go.gov.br/nfe/services/", "https://homolog.sefaz.go.gov.br/nfe/services/"],
        "MG" => [:java, "https://nfce.fazenda.mg.gov.br/nfce/services/", "https://hnfce.fazenda.mg.gov.br/nfce/services/"],
        "MS" => [:java, "https://nfce.sefaz.ms.gov.br/ws/", "https://hom.nfce.sefaz.ms.gov.br/ws/"],
        "MT" => [:am_mt, "https://nfce.sefaz.mt.gov.br/nfcews/services/", "https://homologacao.sefaz.mt.gov.br/nfcews/services/"],
        "PR" => [:java, "https://nfce.sefa.pr.gov.br/nfce/", "https://homologacao.nfce.sefa.pr.gov.br/nfce/"],
        "RS" => [:svrs, "https://nfce.sefazrs.rs.gov.br/ws/", "https://nfce-homologacao.sefazrs.rs.gov.br/ws/"],
        "SP" => [:sp_nfce, "https://nfce.fazenda.sp.gov.br/ws/", "https://homologacao.nfce.fazenda.sp.gov.br/ws/"],
        "SVRS" => [:svrs, "https://nfce.svrs.rs.gov.br/ws/", "https://nfce-homologacao.svrs.rs.gov.br/ws/"]
      }.freeze

      # The "Consulta da NFC-e via QR Code" of each state, [production, homologação], which
      # opens the URL in infNFeSupl/qrCode (RV ZX02-20 rejects another, rej. 395). From the
      # Portal Nacional da NFC-e (nfce.encat.org/desenvolvedor/qrcode), the newer address
      # where it lists a move.
      QR_CODE = {
        "AC" => ["http://www.sefaznet.ac.gov.br/nfce/qrcode", "http://www.hml.sefaznet.ac.gov.br/nfce/qrcode"],
        "AL" => ["http://nfce.sefaz.al.gov.br/QRCode/consultarNFCe.jsp", "http://nfce.sefaz.al.gov.br/QRCode/consultarNFCe.jsp"],
        "AM" => ["https://sistemas.sefaz.am.gov.br/nfceweb/consultarNFCe.jsp", "https://sistemas.sefaz.am.gov.br/nfceweb-hom/consultarNFCe.jsp"],
        "AP" => ["https://www.sefaz.ap.gov.br/nfce/nfcep.php", "https://www.sefaz.ap.gov.br/nfcehml/nfce.php"],
        "BA" => ["http://nfe.sefaz.ba.gov.br/servicos/nfce/qrcode.aspx", "http://hnfe.sefaz.ba.gov.br/servicos/nfce/qrcode.aspx"],
        "CE" => ["http://nfce.sefaz.ce.gov.br/pages/ShowNFCe.html", "http://nfceh.sefaz.ce.gov.br/pages/ShowNFCe.html"],
        "DF" => ["http://www.fazenda.df.gov.br/nfce/qrcode", "http://www.fazenda.df.gov.br/nfce/qrcode"],
        "ES" => ["http://app.sefaz.es.gov.br/ConsultaNFCe/qrcode.aspx", "http://homologacao.sefaz.es.gov.br/ConsultaNFCe/qrcode.aspx"],
        "GO" => ["https://nfeweb.sefaz.go.gov.br/nfeweb/sites/nfce/danfeNFCe", "https://nfewebhomolog.sefaz.go.gov.br/nfeweb/sites/nfce/danfeNFCe"],
        "MA" => ["http://www.nfce.sefaz.ma.gov.br/portal/consultarNFCe.jsp", "http://www.hom.nfce.sefaz.ma.gov.br/portal/consultarNFCe.jsp"],
        "MG" => ["https://portalsped.fazenda.mg.gov.br/portalnfce/sistema/qrcode.xhtml", "https://portalsped.fazenda.mg.gov.br/portalnfce/sistema/qrcode.xhtml"],
        "MS" => ["http://www.dfe.ms.gov.br/nfce/qrcode", "http://www.dfe.ms.gov.br/nfce/qrcode"],
        "MT" => ["http://www.sefaz.mt.gov.br/nfce/consultanfce", "http://homologacao.sefaz.mt.gov.br/nfce/consultanfce"],
        "PA" => ["https://appnfc.sefa.pa.gov.br/portal/view/consultas/nfce/nfceForm.seam", "https://appnfc.sefa.pa.gov.br/portal-homologacao/view/consultas/nfce/nfceForm.seam"],
        "PB" => ["http://www.sefaz.pb.gov.br/nfce", "http://www.sefaz.pb.gov.br/nfcehom"],
        "PE" => ["http://nfce.sefaz.pe.gov.br/nfce/consulta", "http://nfcehomolog.sefaz.pe.gov.br/nfce/consulta"],
        "PI" => ["http://www.sefaz.pi.gov.br/nfce/qrcode", "http://www.sefaz.pi.gov.br/nfce/qrcode"],
        "PR" => ["http://www.fazenda.pr.gov.br/nfce/qrcode", "http://www.fazenda.pr.gov.br/nfce/qrcode"],
        "RJ" => ["https://consultadfe.fazenda.rj.gov.br/consultaNFCe/QRCode", "https://consultadfe.fazenda.rj.gov.br/consultaNFCe/QRCode"],
        "RN" => ["https://nfce.sefaz.rn.gov.br/consultarNFCe.aspx", "https://hom.nfce.sefaz.rn.gov.br/consultarNFCe.aspx"],
        "RO" => ["http://www.nfce.sefin.ro.gov.br/consultanfce/consulta.jsp", "http://www.nfce.sefin.ro.gov.br/consultanfce/consulta.jsp"],
        "RR" => ["https://www.sefaz.rr.gov.br/nfce/servlet/qrcode", "http://200.174.88.103:8080/nfce/servlet/qrcode"],
        "RS" => ["https://www.sefaz.rs.gov.br/NFCE/NFCE-COM.aspx", "https://www.sefaz.rs.gov.br/NFCE/NFCE-COM.aspx"],
        "SC" => ["https://sat.sef.sc.gov.br/nfce/consulta", "https://hom.sat.sef.sc.gov.br/nfce/consulta"],
        "SE" => ["http://www.nfce.se.gov.br/nfce/qrcode", "http://www.hom.nfe.se.gov.br/nfce/qrcode"],
        "SP" => ["https://www.nfce.fazenda.sp.gov.br/qrcode", "https://www.homologacao.nfce.fazenda.sp.gov.br/qrcode"],
        "TO" => ["http://www.sefaz.to.gov.br/nfce/qrcode", "http://homologacao.sefaz.to.gov.br/nfce/qrcode"]
      }.freeze

      # The "Consulta por chave de acesso" of each state, [production, homologação], printed
      # on the DANFE NFC-e and kept in infNFeSupl/urlChave (RV ZX03-20, rej. 878), as the
      # Portal Nacional da NFC-e lists it; MG's moved with its QR code.
      CONSULT = {
        "AC" => ["www.sefaznet.ac.gov.br/nfce/consulta", "www.sefaznet.ac.gov.br/nfce/consulta"],
        "AL" => ["www.sefaz.al.gov.br/nfce/consulta", "www.sefaz.al.gov.br/nfce/consulta"],
        "AM" => ["www.sefaz.am.gov.br/nfce/consulta", "www.sefaz.am.gov.br/nfce/consulta"],
        "AP" => ["www.sefaz.ap.gov.br/nfce/consulta", "www.sefaz.ap.gov.br/nfce/consulta"],
        "BA" => ["www.sefaz.ba.gov.br/nfce/consulta", "http://hinternet.sefaz.ba.gov.br/nfce/consulta"],
        "CE" => ["www.sefaz.ce.gov.br/nfce/consulta", "www.sefaz.ce.gov.br/nfce/consulta"],
        "DF" => ["www.fazenda.df.gov.br/nfce/consulta", "www.fazenda.df.gov.br/nfce/consulta"],
        "ES" => ["www.sefaz.es.gov.br/nfce/consulta", "www.sefaz.es.gov.br/nfce/consulta"],
        "GO" => ["www.sefaz.go.gov.br/nfce/consulta", "www.sefaz.go.gov.br/nfce/consulta"],
        "MA" => ["www.sefaz.ma.gov.br/nfce/consulta", "www.sefaz.ma.gov.br/nfce/consulta"],
        "MG" => ["https://portalsped.fazenda.mg.gov.br/portalnfce", "https://hportalsped.fazenda.mg.gov.br/portalnfce"],
        "MS" => ["www.dfe.ms.gov.br/nfce/consulta", "www.dfe.ms.gov.br/nfce/consulta"],
        "MT" => ["http://www.sefaz.mt.gov.br/nfce/consultanfce", "http://homologacao.sefaz.mt.gov.br/nfce/consultanfce"],
        "PA" => ["www.sefa.pa.gov.br/nfce/consulta", "www.sefa.pa.gov.br/nfce/consulta"],
        "PB" => ["www.sefaz.pb.gov.br/nfce/consulta", "www.sefaz.pb.gov.br/nfcehom"],
        "PE" => ["nfce.sefaz.pe.gov.br/nfce/consulta", "nfce.sefaz.pe.gov.br/nfce/consulta"],
        "PI" => ["www.sefaz.pi.gov.br/nfce/consulta", "www.sefaz.pi.gov.br/nfce/consulta"],
        "PR" => ["http://www.fazenda.pr.gov.br/nfce/consulta", "http://www.fazenda.pr.gov.br/nfce/consulta"],
        "RJ" => ["www.fazenda.rj.gov.br/nfce/consulta", "www.fazenda.rj.gov.br/nfce/consulta"],
        "RN" => ["www.set.rn.gov.br/nfce/consulta", "www.set.rn.gov.br/nfce/consulta"],
        "RO" => ["www.sefin.ro.gov.br/nfce/consulta", "www.sefin.ro.gov.br/nfce/consulta"],
        "RR" => ["www.sefaz.rr.gov.br/nfce/consulta", "www.sefaz.rr.gov.br/nfce/consulta"],
        "RS" => ["www.sefaz.rs.gov.br/nfce/consulta", "www.sefaz.rs.gov.br/nfce/consulta"],
        "SC" => ["https://sat.sef.sc.gov.br/nfce/consulta", "https://hom.sat.sef.sc.gov.br/nfce/consulta"],
        "SE" => ["http://www.nfce.se.gov.br/nfce/consulta", "http://www.hom.nfe.se.gov.br/nfce/consulta"],
        "SP" => ["https://www.nfce.fazenda.sp.gov.br/consulta", "https://www.homologacao.nfce.fazenda.sp.gov.br/consulta"],
        "TO" => ["www.sefaz.to.gov.br/nfce/consulta", "http://homologacao.sefaz.to.gov.br/nfce/consulta.jsf"]
      }.freeze

      module_function

      # The endpoint for a service of a state's NFC-e authorizer.
      #
      #   Endpoints.resolve(uf: "MS", environment: :homologacao, service: :authorization)
      #
      # `overrides` maps service names to URLs that replace the built-in ones.
      def resolve(uf:, environment:, service:, overrides: {})
        definition = SERVICES.fetch(service) { raise ArgumentError, "unknown service: #{service.inspect} (#{SERVICE_KEYS.join(", ")})" }
        authorizer = States.authorizer(uf)
        url = overrides[service] || url_for(authorizer, Environment.normalize(environment), service)

        Endpoint.new(service: service, url: url, namespace: format(Nfe::Endpoints::NAMESPACE, definition[:name]),
          operation: definition[:operation], authorizer: authorizer)
      end

      def url_for(authorizer, environment, service)
        family, production_base, homologacao_base = AUTHORIZERS.fetch(authorizer)
        base = (environment == Environment::PRODUCTION) ? production_base : homologacao_base
        base + PATHS.fetch(family).fetch(service)
      end

      # The address of the state's QR code consultation, before "?p=". `overrides[:qr_code]`
      # replaces it.
      def qr_code(uf:, environment:, overrides: {}) = overrides[:qr_code] || address(QR_CODE, uf, environment)

      # The address of the state's consultation by access key (urlChave).
      # `overrides[:consult_url]` replaces it.
      def consult_url(uf:, environment:, overrides: {}) = overrides[:consult_url] || address(CONSULT, uf, environment)

      def address(table, uf, environment)
        production, homologacao = table.fetch(States.abbreviation(uf))
        (Environment.normalize(environment) == Environment::PRODUCTION) ? production : homologacao
      end
    end
  end
end
