RSpec.describe DfeRb::Nfe::Client do
  let(:transport) { NfeHelpers::FakeTransport.new }
  let(:client) { nfe_client(transport) }
  let(:invoice) { simples_invoice(client) }
  let(:signed) { client.sign(invoice) }

  describe "#status" do
    it "asks the issuer's authorizer" do
      transport.answer(:status, ret_cons_stat_serv)

      status = client.status

      expect(status).to be_online
      expect(status.message).to eq("Servico em Operacao")
      expect(status.average_seconds).to eq(1)
      call = transport.calls.first
      expect(call.url).to eq("https://homologacao.nfe.fazenda.sp.gov.br/ws/nfestatusservico4.asmx")
      expect(call.xml).to eq(%(<consStatServ xmlns="#{NfeHelpers::NFE_NS}" versao="4.00"><tpAmb>2</tpAmb><cUF>35</cUF><xServ>STATUS</xServ></consStatServ>))
    end

    it "reports an authorizer that is down" do
      transport.answer(:status, ret_cons_stat_serv(code: 109, message: "Paralisado"))
      expect(client.status).not_to be_online
    end
  end

  describe "#sign" do
    it "produces a verified signed NFe with its key and digest" do
      expect(signed.key).to eq(invoice.key.to_s)
      expect(signed.xml).to start_with("<NFe ")
      expect(DfeRb::Nfe::Signature.verify(signed.xml)).to be(true)
      expect(signed.digest_value).to eq(DfeRb::Nfe::Signature.digest_value(signed.xml))
    end

    it "is idempotent for already signed input" do
      expect(client.sign(signed)).to be(signed)
      expect(client.sign(signed.xml).xml).to eq(signed.xml)
    end

    it "signs raw XML handed in by the app" do
      raw = client.sign(invoice.to_xml)
      expect(raw.key).to eq(invoice.key.to_s)
      expect(DfeRb::Nfe::Signature.verify(raw.xml)).to be(true)
    end

    it "refuses an NFe built for the other environment" do
      production = simples_invoice(client)
      xml = production.to_xml.sub("<tpAmb>2</tpAmb>", "<tpAmb>1</tpAmb>")

      expect { client.sign(xml) }.to raise_error(DfeRb::ValidationError, /production/)
    end

    it "checks a SignedInvoice against this client's environment and its signature" do
      production = nfe_client(transport, environment: :production)
      expect { production.sign(signed) }.to raise_error(DfeRb::ValidationError, /built for homologacao/)

      restored = DfeRb::Nfe::SignedInvoice.new(xml: signed.xml.sub("<natOp>Venda de mercadoria</natOp>", "<natOp>Outra</natOp>"), key: nil, digest_value: nil)
      expect { client.sign(restored) }.to raise_error(DfeRb::ValidationError, /does not verify: digest mismatch/)
    end

    it "fills the key and digest of a SignedInvoice restored from storage" do
      restored = client.sign(DfeRb::Nfe::SignedInvoice.new(xml: signed.xml, key: nil, digest_value: nil))
      expect(restored).to eq(signed)
    end

    it "validates raw XML against the schema and the business rules" do
      without_nature = invoice.to_xml.sub("<natOp>Venda de mercadoria</natOp>", "")
      expect { client.sign(without_nature) }.to raise_error(DfeRb::ValidationError, /natOp/)

      bad_cnpj = invoice.to_xml.sub("<CNPJ>11222333000181</CNPJ>", "<CNPJ>11222333000182</CNPJ>")
      expect { client.sign(bad_cnpj) }.to raise_error(DfeRb::ValidationError, /dest\/CNPJ: 11222333000182 is not a valid CNPJ/)
      expect(client.sign(bad_cnpj, strict: false).key).to eq(invoice.key.to_s)
    end

    it "reads the key and issuer however the XML is quoted or indented" do
      quoted = signed.xml.sub(%(Id="NFe#{signed.key}"), %(Id='NFe#{signed.key}'))
      expect(client.sign(quoted).key).to eq(signed.key)

      other = nfe_client(transport).tap { |c| c.instance_variable_set(:@certificate, nfe_certificate(cnpj: "11222333000181")) }
      indented = signed.xml.sub("<emit><CNPJ>", "<emit>\n  <CNPJ>")
      expect { other.sign(indented) }.to raise_error(DfeRb::ValidationError, /CNPJ root 11222333 but the issuer is 11444777000161/)
    end

    it "refuses a person's certificate for a company's invoice" do
      cert, key = icp_certificate(oid: "2.16.76.1.3.1", value: "0101198052998224725#{"0" * 24}")
      person = nfe_client(transport).tap { |c| c.instance_variable_set(:@certificate, DfeRb::Certificate.new(certificate: cert, private_key: key)) }

      expect { person.sign(signed.xml) }.to raise_error(DfeRb::ValidationError, /belongs to CPF 52998224725 but the issuer is 11444777000161 \(rej. 213\)/)
    end

    it "drops the XML declaration of signed input so lots and nfeProc stay well-formed" do
      declared = client.sign(%(<?xml version="1.0" encoding="UTF-8"?>\n#{signed.xml}))
      expect(declared.xml).to eq(signed.xml)

      transport.answer(:authorization, ret_env_nfe_sync(prot_nfe(signed.key, digest: signed.digest_value)))
      result = client.authorize(%(<?xml version="1.0" encoding="UTF-8"?>#{signed.xml}))

      expect(Nokogiri::XML(transport.calls_to(:authorization).first.xml) { |c| c.strict }.errors).to be_empty
      expect(Nokogiri::XML(result.proc_xml) { |c| c.strict }.errors).to be_empty
    end

    it "raises with every problem when the invoice is invalid" do
      bad = client.build_invoice { |nfe| nfe.number 1 }
      expect { client.sign(bad) }.to raise_error(DfeRb::ValidationError)
    end
  end

  describe "#authorize (one note, synchronous)" do
    it "returns the authorization with the nfeProc to archive" do
      transport.answer(:authorization, ->(_xml) { ret_env_nfe_sync(prot_nfe(signed.key, digest: signed.digest_value)) })

      result = client.authorize(signed)

      expect(result).to be_authorized
      expect(result.status).to eq(:authorized)
      expect(result.code).to eq(100)
      expect(result.protocol).to eq("135260000000123")
      expect(result.key).to eq(signed.key)
      expect(result).not_to be_recovered
      expect(result.filename).to eq("#{signed.key}-procNFe.xml")

      request = transport.calls_to(:authorization).first
      body = Nokogiri::XML(request.xml)
      expect(body.at_xpath("//nfe:indSinc", "nfe" => NfeHelpers::NFE_NS).text).to eq("1")
      expect(request.xml).to include(signed.xml)

      proc = Nokogiri::XML(result.proc_xml)
      expect(proc.root.name).to eq("nfeProc")
      expect(proc.root["versao"]).to eq("4.00")
      expect(result.proc_xml).to include(signed.xml)
      expect(proc.at_xpath("//nfe:protNFe/nfe:infProt/nfe:nProt", "nfe" => NfeHelpers::NFE_NS).text).to eq("135260000000123")
      expect(proc.root.element_children.map(&:name)).to eq(%w[NFe protNFe])
    end

    it "accepts an Invoice or raw XML and signs it" do
      transport.answer(:authorization, ->(xml) {
        key = xml[/Id="NFe(\d{44})"/, 1]
        ret_env_nfe_sync(prot_nfe(key))
      })

      expect(client.authorize(invoice)).to be_authorized
      expect(client.authorize(invoice.to_xml)).to be_authorized
    end

    it "keeps alerts of an authorization with warnings (cStat 120)" do
      alerts = [{code: "9001", message: "Destinatario com CNPJ irregular"}]
      transport.answer(:authorization, ret_env_nfe_sync(prot_nfe(signed.key, code: 120, message: "Autorizado com alerta", alerts: alerts)))

      result = client.authorize(signed)

      expect(result.status).to eq(:authorized_with_alert)
      expect(result).to be_authorized
      expect(result.alerts).to eq([{code: "9001", message: "Destinatario com CNPJ irregular"}])
    end

    it "flags late authorizations (150)" do
      transport.answer(:authorization, ret_env_nfe_sync(prot_nfe(signed.key, code: 150, message: "Autorizado fora de prazo")))
      expect(client.authorize(signed).status).to eq(:authorized_late)
    end

    it "returns rejections as results" do
      transport.answer(:authorization, ret_env_nfe_sync(prot_nfe(signed.key, code: 209, message: "Rejeicao: IE do emitente invalida", protocol: nil)))

      result = client.authorize(signed)

      expect(result).to be_rejected
      expect(result).not_to be_authorized
      expect(result.code).to eq(209)
      expect(result.message).to eq("Rejeicao: IE do emitente invalida")
      expect(result.proc_xml).to be_nil
    end

    it "explains lot-level rejections that carry no protocol" do
      transport.answer(:authorization, ret_env_nfe(code: 225, message: "Rejeicao: Falha no Schema XML do lote de NFe", receipt: nil))

      result = client.authorize(signed)

      expect(result).to be_rejected
      expect(result.code).to eq(225)
    end

    it "treats a denial as a stored note with its own nfeProc" do
      transport.answer(:authorization, ret_env_nfe_sync(prot_nfe(signed.key, code: 110, message: "Uso Denegado")))

      result = client.authorize(signed)

      expect(result).to be_denied
      expect(result).not_to be_authorized
      expect(result.proc_xml).to include("<nfeProc")
    end

    it "marks consumption blocks (656)" do
      transport.answer(:authorization, ret_env_nfe(code: 656, message: "Rejeicao: Consumo Indevido", receipt: nil))
      expect(client.authorize(signed)).to be_blocked
    end
  end

  describe "#authorize!" do
    it "returns the result when authorized" do
      transport.answer(:authorization, ret_env_nfe_sync(prot_nfe(signed.key)))
      expect(client.authorize!(signed)).to be_authorized
    end

    it "raises Rejected, Denied and ConsumptionBlocked with the result" do
      transport.answer(:authorization, ret_env_nfe_sync(prot_nfe(signed.key, code: 209, message: "IE invalida", protocol: nil)))
      expect { client.authorize!(signed) }.to raise_error(DfeRb::Nfe::Rejected, "209 IE invalida") { |error| expect(error.result.code).to eq(209) }

      transport.replace(:authorization, ret_env_nfe_sync(prot_nfe(signed.key, code: 301, message: "Uso Denegado: Irregularidade fiscal do emitente")))
      expect { client.authorize!(signed) }.to raise_error(DfeRb::Nfe::Denied)

      transport.replace(:authorization, ret_env_nfe(code: 656, message: "Consumo Indevido", receipt: nil))
      expect { client.authorize!(signed) }.to raise_error(DfeRb::Nfe::ConsumptionBlocked)
    end
  end

  describe "#authorize (a lot of several notes)" do
    # Before the day SEFAZ stops taking the asynchronous lot (RV GAP03a-6), so these don't age.
    let(:clock) { Struct.new(:now).new(Time.new(2026, 11, 16, 10, 0, 0, "-03:00")) }
    let(:client) { nfe_client(transport, clock: clock) }
    let(:invoices) { [simples_invoice(client, number: 1), simples_invoice(client, number: 2)] }
    let(:notes) { invoices.map { |item| client.sign(item) } }

    it "sends an asynchronous lot, waits, polls the receipt and maps each protocol to its note" do
      sleeps = []
      polling_client = nfe_client(transport, clock: clock).tap { |c| c.instance_variable_set(:@sleeper, ->(seconds) { sleeps << seconds }) }
      transport.answer(:authorization, ret_env_nfe(receipt: "351000000012345"))
      transport.answer(:authorization_return,
        ret_cons_reci_nfe([], code: 105, message: "Lote em processamento"),
        ret_cons_reci_nfe([prot_nfe(notes[1].key, protocol: "135260000000002"), prot_nfe(notes[0].key, code: 209, message: "Rejeicao", protocol: nil)]))

      results = polling_client.authorize(notes)

      expect(results.map(&:key)).to eq(notes.map(&:key))
      expect(results.map(&:code)).to eq([209, 100])
      expect(results.map(&:protocol)).to eq([nil, "135260000000002"])
      expect(results.map(&:receipt)).to eq(["351000000012345"] * 2)
      expect(sleeps).to eq([15, 5])

      lot = Nokogiri::XML(transport.calls_to(:authorization).first.xml)
      expect(lot.at_xpath("//nfe:indSinc", "nfe" => NfeHelpers::NFE_NS).text).to eq("0")
      expect(lot.xpath("//nfe:NFe", "nfe" => NfeHelpers::NFE_NS).size).to eq(2)
      expect(transport.calls_to(:authorization_return).first.xml).to include("<nRec>351000000012345</nRec>")
    end

    it "gives up polling after max_wait and reports the lot as still processing" do
      transport.answer(:authorization, ret_env_nfe)
      transport.answer(:authorization_return, ret_cons_reci_nfe([], code: 105, message: "Lote em processamento"))

      results = client.authorize(notes, polling: {wait: 1, interval: 5, max_wait: 11})

      expect(results.map(&:code)).to eq([105, 105])
      expect(results.map(&:status)).to eq(%i[pending pending])
      expect(results.first.receipt).to eq("351000000012345")
      expect(transport.calls_to(:authorization_return).size).to eq(3)
    end

    it "keeps the receipt when polling fails, and #resume finishes the lot" do
      transport.answer(:authorization, ret_env_nfe(receipt: "351000000012345"))
      transport.answer(:authorization_return, DfeRb::TransportError.new("ReadTimeout"))
      transport.answer(:consult, ret_cons_sit_nfe(notes[0].key, code: 217, message: "NF-e nao consta na base de dados da SEFAZ"))

      pending = client.authorize(notes)

      expect(pending.map(&:status)).to eq(%i[pending pending])
      expect(pending.map(&:receipt)).to eq(["351000000012345"] * 2)
      expect(pending.first.message).to include("ReadTimeout")

      transport.replace(:authorization_return, ret_cons_reci_nfe([prot_nfe(notes[0].key), prot_nfe(notes[1].key, protocol: "135260000000002")]))
      results = client.resume(pending.first.receipt, pending)

      expect(results.map(&:status)).to eq(%i[authorized authorized])
      expect(results.map(&:protocol)).to eq(%w[135260000000123 135260000000002])
      expect(results.first.proc_xml).to include(notes[0].xml)
      expect(transport.calls_to(:authorization_return).last.xml).to include("<nRec>351000000012345</nRec>")
    end

    it "looks the notes up when polling fails and SEFAZ already has them" do
      transport.answer(:authorization, ret_env_nfe)
      transport.answer(:authorization_return, DfeRb::TransportError.new("ReadTimeout"))
      transport.answer(:consult, ->(xml) {
        note = notes.find { |n| xml.include?(n.key) }
        ret_cons_sit_nfe(note.key, protocol_xml: prot_nfe(note.key, digest: note.digest_value))
      })

      results = client.authorize(notes)

      expect(results.map(&:status)).to eq(%i[authorized authorized])
      expect(results).to all(be_recovered)
    end

    # RV GAP03a-6, NT 2023.002 v1.02: SEFAZ rejects indSinc 0 (rej. 129) from 01/02/2027 in
    # homologação and 05/04/2027 in production.
    describe "when SEFAZ ends the asynchronous lot (RV GAP03a-6, rej. 129)" do
      def clock_at(*time) = Struct.new(:now).new(Time.new(*time, "-03:00"))

      def client_at(clock, environment: :homologacao) = nfe_client(transport, clock: clock, environment: environment)

      def lot_of_two(client)
        [client.sign(simples_invoice(client, number: 1)), client.sign(simples_invoice(client, number: 2))]
      end

      it "sends a lot the day before it ends in homologação, and refuses it on the day" do
        eve = client_at(clock_at(2027, 1, 31, 23, 59, 59))
        eve_notes = lot_of_two(eve)
        transport.answer(:authorization, ret_env_nfe)
        transport.answer(:authorization_return, ret_cons_reci_nfe(eve_notes.map { |note| prot_nfe(note.key) }))
        expect(eve.authorize(eve_notes).map(&:status)).to eq(%i[authorized authorized])

        day = client_at(clock_at(2027, 2, 1, 0, 0, 0))
        expect { day.authorize(lot_of_two(day)) }.to raise_error(DfeRb::ValidationError) { |error|
          expect(error.issues.first).to include("a lot of 2 notes is an asynchronous request (indSinc 0)", "since 01/02/2027 in homologacao",
            "RV GAP03a-6, rej. 129", "NT 2023.002 v1.02", "authorize each note in its own call")
        }
        expect(transport.calls_to(:authorization).size).to eq(1)
      end

      it "keeps the production lot until 05/04/2027" do
        eve = client_at(clock_at(2027, 4, 4, 23, 59, 59), environment: :production)
        invoices = [simples_invoice(eve, number: 1), simples_invoice(eve, number: 2)]
        eve_notes = invoices.map { |note| eve.sign(note) }
        transport.answer(:authorization, ret_env_nfe)
        transport.answer(:authorization_return, ret_cons_reci_nfe(eve_notes.map { |note| prot_nfe(note.key) }))

        expect(eve.authorize(eve_notes).map(&:status)).to eq(%i[authorized authorized])

        day = client_at(clock_at(2027, 4, 5, 0, 0, 0), environment: :production)
        expect { day.authorize(invoices.map { |note| day.sign(note) }) }.to raise_error(DfeRb::ValidationError, /since 05\/04\/2027 in production/)
      end

      it "refuses it by the clock of the request even for notes issued before" do
        late = client_at(clock_at(2027, 2, 2, 9, 0, 0))

        expect { late.authorize(notes) }.to raise_error(DfeRb::ValidationError, /rej. 129/)
        expect(transport.calls).to be_empty
      end

      it "refuses it by a note's dhEmi even when the clock is before" do
        issuing = client_at(clock_at(2027, 2, 2, 9, 0, 0))
        later_notes = lot_of_two(issuing)

        expect { client.authorize(later_notes) }.to raise_error(DfeRb::ValidationError, /rej. 129/)
        expect(transport.calls).to be_empty
      end

      it "still sends one note on its own after the day" do
        day = client_at(clock_at(2027, 6, 1, 9, 0, 0))
        note = lot_of_two(day).first
        transport.answer(:authorization, ret_env_nfe_sync(prot_nfe(note.key)))

        expect(day.authorize(note)).to be_authorized
        expect(day.authorize([note]).map(&:status)).to eq([:authorized])
        expect(transport.calls_to(:authorization).map { |call| call.xml[%r{<indSinc>(\d)</indSinc>}, 1] }).to eq(%w[1 1])
      end

      it "sends several notes one at a time" do
        day = client_at(clock_at(2027, 6, 1, 9, 0, 0))
        two = lot_of_two(day)
        transport.answer(:authorization, ->(xml) { ret_env_nfe_sync(prot_nfe(two.find { |note| xml.include?(note.key) }.key)) })

        results = two.map { |note| day.authorize(note) }

        expect(results.map(&:status)).to eq(%i[authorized authorized])
        expect(transport.calls_to(:authorization).size).to eq(2)
      end
    end

    it "rejects lots that are empty or above 50 notes" do
      expect { client.authorize([]) }.to raise_error(ArgumentError, /nothing/)
      expect { client.authorize([signed] * 51) }.to raise_error(ArgumentError, /at most 50/)
    end
  end

  describe "recovering from lost or ambiguous answers" do
    let(:timeout) { DfeRb::TransportError.new("ReadTimeout", maybe_processed: true) }

    it "adopts the protocol found by key when the note is the very same document" do
      transport.answer(:authorization, timeout)
      transport.answer(:consult, ->(_xml) {
        ret_cons_sit_nfe(signed.key, protocol_xml: prot_nfe(signed.key, digest: signed.digest_value))
      })

      result = client.authorize(signed)

      expect(result).to be_authorized
      expect(result).to be_recovered
      expect(result.protocol).to eq("135260000000123")
      expect(result.proc_xml).to include(signed.xml)
    end

    it "keeps saying the note may have been processed when the lookup fails too" do
      transport.answer(:authorization, DfeRb::TransportError.new("ReadTimeout", maybe_processed: true))
      transport.answer(:consult, DfeRb::TransportError.new("could not connect", maybe_processed: false))

      expect { client.authorize(signed) }.to raise_error(DfeRb::TransportError, "ReadTimeout") { |error| expect(error).to be_maybe_processed }
    end

    it "reports a note canceled since as canceled, never as authorized" do
      transport.answer(:authorization, timeout)
      transport.answer(:consult, ->(_xml) {
        ret_cons_sit_nfe(signed.key, code: 101, message: "Cancelamento de NF-e homologado",
          protocol_xml: prot_nfe(signed.key, digest: signed.digest_value))
      })

      result = client.authorize(signed)

      expect(result).not_to be_authorized
      expect(result).to be_canceled
      expect(result.code).to eq(101)
      expect(result.protocol).to eq("135260000000123")
      expect(result.proc_xml).to include(signed.xml)
      expect { client.authorize!(signed) }.to raise_error(DfeRb::Nfe::Rejected, /101/)
    end

    it "re-raises the transport error when SEFAZ never saw the note (safe to send the same XML again)" do
      transport.answer(:authorization, timeout)
      transport.answer(:consult, ret_cons_sit_nfe(signed.key, code: 217, message: "NF-e nao consta na base de dados da SEFAZ"))

      expect { client.authorize(signed) }.to raise_error(DfeRb::TransportError, "ReadTimeout")
    end

    it "does not look anything up when the request certainly never went out" do
      transport.answer(:authorization, DfeRb::TransportError.new("could not connect", maybe_processed: false))

      expect { client.authorize(signed) }.to raise_error(DfeRb::TransportError, /could not connect/)
      expect(transport.calls_to(:consult)).to be_empty
    end

    it "does not recover when recover: false" do
      transport.answer(:authorization, timeout)
      expect { client.authorize(signed, recover: false) }.to raise_error(DfeRb::TransportError)
      expect(transport.calls_to(:consult)).to be_empty
    end

    it "resolves a duplicate report (204) by looking the key up" do
      transport.answer(:authorization, ret_env_nfe_sync(prot_nfe(signed.key, code: 204, message: "Rejeicao: Duplicidade de NF-e [nRec:351000000012345]", protocol: nil)))
      transport.answer(:consult, ret_cons_sit_nfe(signed.key, protocol_xml: prot_nfe(signed.key, digest: signed.digest_value)))

      result = client.authorize(signed)

      expect(result).to be_authorized
      expect(result).to be_recovered
    end

    it "raises Conflict when the stored note differs from the one being sent" do
      transport.answer(:authorization, ret_env_nfe_sync(prot_nfe(signed.key, code: 204, message: "Duplicidade de NF-e", protocol: nil)))
      transport.answer(:consult, ret_cons_sit_nfe(signed.key, protocol_xml: prot_nfe(signed.key, digest: "BBBBBBBBBBBBBBBBBBBBBBBBBBB=")))

      expect { client.authorize(signed) }.to raise_error(DfeRb::Nfe::Conflict, /different content/)
    end

    it "returns the rejection as is when the key is unknown (539 for another key)" do
      transport.answer(:authorization, ret_env_nfe_sync(prot_nfe(signed.key, code: 539, message: "Duplicidade de NF-e com diferenca na Chave de Acesso [chNFe:35260911444777000161550010000000019999999992]", protocol: nil)))
      transport.answer(:consult, ret_cons_sit_nfe(signed.key, code: 217, message: "NF-e nao consta na base de dados da SEFAZ"))

      result = client.authorize(signed)

      expect(result).to be_rejected
      expect(result.code).to eq(539)
      expect(result.message).to include("[chNFe:")
    end
  end

  describe "#consult" do
    it "routes by the key's state and reads protocol and events" do
      key = signed.key
      event = %(<procEventoNFe xmlns="#{NfeHelpers::NFE_NS}" versao="1.00"><evento versao="1.00"><infEvento><tpEvento>110111</tpEvento>) +
        %(<nSeqEvento>1</nSeqEvento><detEvento versao="1.00"><descEvento>Cancelamento</descEvento></detEvento></infEvento></evento>) +
        %(<retEvento versao="1.00"><infEvento><cStat>135</cStat><xMotivo>Evento registrado</xMotivo><nProt>135260000000999</nProt></infEvento></retEvento></procEventoNFe>)
      transport.answer(:consult, ret_cons_sit_nfe(key, code: 101, message: "Cancelamento de NF-e homologado", protocol_xml: prot_nfe(key, digest: "ZZZZZZZZZZZZZZZZZZZZZZZZZZZ="), events: [event]))

      result = client.consult(key)

      expect(result.status).to eq(:canceled)
      expect(result).to be_canceled
      expect(result.protocol).to eq("135260000000123")
      expect(result.digest_value).to eq("ZZZZZZZZZZZZZZZZZZZZZZZZZZZ=")
      expect(result.events.map(&:type)).to eq(["110111"])
      expect(result.events.first.code).to eq(135)
      expect(result.events.first.protocol).to eq("135260000000999")
      expect(result.events.first.xml).to eq(event)
      expect(transport.calls.first.url).to include("homologacao.nfe.fazenda.sp.gov.br")
    end

    it "sends a key of another state to that state's authorizer" do
      other = DfeRb::Nfe::AccessKey.build(state: "MG", issued_at: Time.new(2026, 9, 1), tax_id: "11444777000161", series: 1, number: 5, numeric_code: "12345670")
      transport.answer(:consult, ret_cons_sit_nfe(other.to_s, code: 217, message: "NF-e nao consta na base de dados da SEFAZ"))

      result = client.consult(other.to_s)

      expect(result.status).to eq(:not_found)
      expect(result).not_to be_found
      expect(transport.calls.first.url).to start_with("https://hnfe.fazenda.mg.gov.br/")
    end

    it "rejects a malformed key" do
      expect { client.consult("123") }.to raise_error(ArgumentError, /invalid access key/)
    end
  end

  describe "events" do
    it "cancels a note with a signed evento in an envEvento" do
      transport.answer(:event, ret_env_evento(signed.key, type: "110111"))

      result = client.cancel(signed.key, protocol: "135260000000123", reason: "Erro na digitacao dos dados da nota")

      expect(result).to be_registered
      expect(result.type).to eq("110111")
      expect(result.code).to eq(135)
      expect(result.protocol).to eq("135260000000999")

      request = transport.calls_to(:event).first
      doc = Nokogiri::XML(request.xml)
      ns = {"nfe" => NfeHelpers::NFE_NS}
      info = doc.at_xpath("//nfe:infEvento", ns)
      expect(info["Id"]).to eq("ID110111#{signed.key}01")
      expect(info.at_xpath("nfe:cOrgao", ns).text).to eq("35")
      expect(info.at_xpath("nfe:tpAmb", ns).text).to eq("2")
      expect(info.at_xpath("nfe:CNPJ", ns).text).to eq("11444777000161")
      expect(info.at_xpath("nfe:detEvento/nfe:descEvento", ns).text).to eq("Cancelamento")
      expect(info.at_xpath("nfe:detEvento/nfe:nProt", ns).text).to eq("135260000000123")
      expect(DfeRb::Nfe::Signature.verify(request.xml)).to be(true)
      expect(Nokogiri::XML(result.proc_xml).root.name).to eq("procEventoNFe")
      expect(result.filename).to eq("#{signed.key}_110111_01-procEventoNFe.xml")
    end

    it "validates cancellation arguments" do
      expect { client.cancel(signed.key, protocol: "123", reason: "Erro na digitacao dos dados") }.to raise_error(ArgumentError, /protocol/)
      expect { client.cancel(signed.key, protocol: "135260000000123", reason: "curto") }.to raise_error(ArgumentError, /reason must have 15 to 255/)
    end

    it "sends a correction letter with the mandatory conditions of use" do
      transport.answer(:event, ret_env_evento(signed.key, type: "110110", sequence: 2, message: "Evento registrado e vinculado a NF-e"))

      result = client.correct(signed.key, text: "Corrigir o endereco de entrega da mercadoria", sequence: 2)

      expect(result).to be_registered
      xml = transport.calls_to(:event).first.xml
      expect(xml).to include("<nSeqEvento>2</nSeqEvento>", "<descEvento>Carta de Correcao</descEvento>")
      expect(xml).to include("A Carta de Correcao e disciplinada pelo paragrafo 1o-A do art. 7o do Convenio S/N")
      expect(xml).to include("ID110110#{signed.key}02")
      expect(result.filename).to eq("#{signed.key}_110110_02-procEventoNFe.xml")
    end

    it "reports an event SEFAZ refused" do
      transport.answer(:event, ret_env_evento(signed.key, type: "110111", code: 494, message: "Rejeicao: Chave de Acesso inexistente", protocol: nil))

      result = client.cancel(signed.key, protocol: "135260000000123", reason: "Erro na digitacao dos dados da nota")

      expect(result).not_to be_registered
      expect(result.code).to eq(494)
      expect(result.proc_xml).to be_nil
    end
  end

  describe "#inutilize" do
    let(:clock) { Struct.new(:now).new(Time.new(2026, 11, 16, 10, 0, 0, "-03:00")) }
    let(:client) { DfeRb::Nfe::Client.new(certificate: nfe_certificate, uf: "MS", transport: transport, clock: clock, sleeper: ->(_seconds) {}) }
    let(:reason) { "Numeracao pulada por erro no sistema" }

    it "signs and sends the request for a range" do
      transport.answer(:inutilization, ret_inut_nfe)

      result = client.inutilize(series: 1, from: 10, to: 12, reason: reason, year: 2026)

      expect(result).to be_approved
      expect(result.protocol).to eq("135260000000777")
      xml = transport.calls_to(:inutilization).first.xml
      doc = Nokogiri::XML(xml)
      ns = {"nfe" => NfeHelpers::NFE_NS}
      expect(doc.at_xpath("//nfe:infInut/@Id", ns).value).to eq("ID50261144477700016155001000000010000000012")
      expect(doc.at_xpath("//nfe:nNFIni", ns).text).to eq("10")
      expect(doc.at_xpath("//nfe:nNFFin", ns).text).to eq("12")
      expect(doc.at_xpath("//nfe:xServ", ns).text).to eq("INUTILIZAR")
      expect(DfeRb::Nfe::Signature.verify(xml)).to be(true)
      expect(Nokogiri::XML(result.proc_xml).root.name).to eq("ProcInutNFe")
    end

    it "validates the range and the reason" do
      expect { client.inutilize(series: 1, from: 12, to: 10, reason: "Numeracao pulada por erro") }.to raise_error(ArgumentError, /greater/)
      expect { client.inutilize(series: 1, from: 1, to: 10_001, reason: "Numeracao pulada por erro") }.to raise_error(ArgumentError, /10000/)
      expect { client.inutilize(series: 1, from: 1, reason: "curto") }.to raise_error(ArgumentError, /reason/)
    end

    it "defaults to a single number" do
      transport.answer(:inutilization, ret_inut_nfe)
      client.inutilize(series: 1, from: 10, reason: reason, year: 2026)
      expect(transport.calls_to(:inutilization).first.xml).to include("<nNFIni>10</nNFIni><nNFFin>10</nNFFin>")
    end

    # RV I01a, NT 2023.002 v1.02: AC, BA and SP have no inutilização service from 11/11/2026.
    describe "in AC, BA and SP (RV I01a)" do
      %w[AC BA SP].each do |state|
        it "refuses #{state} before sending anything, naming the Ajustes SINIEF" do
          off = DfeRb::Nfe::Client.new(certificate: nfe_certificate, uf: state, transport: transport, clock: clock)

          expect { off.inutilize(series: 1, from: 10, reason: reason) }.to raise_error(DfeRb::Nfe::Unsupported) { |error|
            expect(error.message).to include("inutilização service of #{state} is switched off since 11/11/2026",
              "Ajustes SINIEF 38/2026 and 40/2026", "RV I01a, rej. 998", "NT 2023.002 v1.02")
          }
          expect(transport.calls).to be_empty
        end
      end

      it "refuses the NFC-e's inutilização too" do
        off = DfeRb::Nfce::Client.new(certificate: nfe_certificate, uf: "SP", transport: transport, clock: clock)

        expect { off.inutilize(series: 1, from: 10, reason: reason) }.to raise_error(DfeRb::Nfe::Unsupported, /Ajustes SINIEF 38\/2026/)
        expect(transport.calls).to be_empty
      end

      it "still sends it the day before, and on the day refuses" do
        transport.answer(:inutilization, ret_inut_nfe)
        before = Struct.new(:now).new(Time.new(2026, 11, 10, 23, 59, 59, "-03:00"))
        sp = ->(clock) { DfeRb::Nfe::Client.new(certificate: nfe_certificate, uf: "SP", transport: transport, clock: clock) }

        expect(sp.call(before).inutilize(series: 1, from: 10, reason: reason, year: 2026)).to be_approved
        expect { sp.call(Struct.new(:now).new(Time.new(2026, 11, 11, 0, 0, 0, "-03:00"))).inutilize(series: 1, from: 10, reason: reason) }
          .to raise_error(DfeRb::Nfe::Unsupported)
        expect(transport.calls_to(:inutilization).size).to eq(1)
      end

      it "is checked in homologação and in production alike" do
        production = DfeRb::Nfe::Client.new(certificate: nfe_certificate, uf: "BA", environment: :production, transport: transport, clock: clock)

        expect { production.inutilize(series: 1, from: 10, reason: reason) }.to raise_error(DfeRb::Nfe::Unsupported, /BA is switched off/)
      end

      it "leaves the other states' service alone" do
        transport.answer(:inutilization, ret_inut_nfe)

        expect(client.inutilize(series: 1, from: 10, reason: reason, year: 2026)).to be_approved
      end
    end

    describe "when SEFAZ says the service is off" do
      it "reads 998 (Serviço Desativado) as the service being off" do
        transport.answer(:inutilization, ret_inut_nfe(code: 998, message: "Rejeicao: Servico Desativado", protocol: nil))

        expect { client.inutilize(series: 1, from: 10, reason: reason) }.to raise_error(DfeRb::Nfe::Unsupported) { |error|
          expect(error.message).to include("SEFAZ MS answered 998 Rejeicao: Servico Desativado", "RV I01a", "AC, BA and SP have since 11/11/2026")
        }
      end

      it "reads an HTTP 404 as the service being off" do
        transport.answer(:inutilization, DfeRb::TransportError.new("HTTP 404 from nfe.example", maybe_processed: false, http_status: 404))

        expect { client.inutilize(series: 1, from: 10, reason: reason) }.to raise_error(DfeRb::Nfe::Unsupported, /SEFAZ MS answered HTTP 404/)
      end

      it "names the Ajustes when a listed state answers it ahead of the date" do
        early = Struct.new(:now).new(Time.new(2026, 11, 10, 12, 0, 0, "-03:00"))
        sp = DfeRb::Nfe::Client.new(certificate: nfe_certificate, uf: "SP", transport: transport, clock: early)
        transport.answer(:inutilization, ret_inut_nfe(code: 998, message: "Rejeicao: Servico Desativado", protocol: nil))

        expect { sp.inutilize(series: 1, from: 10, reason: reason) }.to raise_error(DfeRb::Nfe::Unsupported, /SEFAZ SP answered 998.*Ajustes SINIEF 38\/2026/)
      end

      it "keeps raising any other transport error as it was" do
        transport.answer(:inutilization, DfeRb::TransportError.new("HTTP 500 from nfe.example", maybe_processed: true, http_status: 500))

        expect { client.inutilize(series: 1, from: 10, reason: reason) }.to raise_error(DfeRb::TransportError, /HTTP 500/)
      end

      it "returns any other rejection as a result" do
        transport.answer(:inutilization, ret_inut_nfe(code: 563, message: "Rejeicao: Ja existe pedido de inutilizacao", protocol: nil))

        expect(client.inutilize(series: 1, from: 10, reason: reason)).not_to be_approved
      end
    end
  end

  describe "configuration" do
    it "uses homologacao unless told otherwise, and production only when asked" do
      expect(client.environment).to eq(:homologacao)
      expect(client).not_to be_production
      prod = nfe_client(transport, environment: :production)
      expect(prod).to be_production
      expect(prod.endpoint(:authorization).url).to eq("https://nfe.fazenda.sp.gov.br/ws/nfeautorizacao4.asmx")
    end

    it "lets the caller override URLs and send raw XML" do
      custom = nfe_client(transport, endpoints: {status: "https://proxy.example/status"})
      transport.answer(:status, "<ok/>")

      expect(custom.raw(:status, "<consStatServ/>")).to eq("<ok/>")
      expect(transport.calls.first.url).to eq("https://proxy.example/status")
    end

    it "builds invoices for its own environment" do
      expect(nfe_client(transport, environment: :production).build_invoice.environment).to eq(:production)
    end

    it "puts its technical contact on every invoice, signing it with the CSRT" do
      contact = {cnpj: "11222333000181", contact: "Dev", email: "dev@example.com", phone: "11999999999", csrt_id: "01", csrt: "SECRET"}
      invoice = simples_invoice(nfe_client(transport, technical_contact: contact))
      key = invoice.key.to_s
      xml = invoice.to_xml

      group = Nokogiri::XML(xml).at_xpath("//nfe:infRespTec", "nfe" => NfeHelpers::NFE_NS)
      expect(group.at_xpath("nfe:idCSRT", "nfe" => NfeHelpers::NFE_NS).text).to eq("01")
      expect(group.at_xpath("nfe:hashCSRT", "nfe" => NfeHelpers::NFE_NS).text).to eq(Base64.strict_encode64(Digest::SHA1.digest("SECRET#{key}")))
      expect(xml).not_to include("SECRET")
    end
  end
end
