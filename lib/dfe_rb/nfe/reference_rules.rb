module DfeRb
  module Nfe
    # How an NF-e references the notes it refers to, as NT 2025.002 v1.53 has it, in the
    # header (ide/NFref) or on each item (det/DFeReferenciado, the group of RV VC02). It
    # checks what a note says about itself and its own keys; what needs the referenced
    # note's data (its totals, its direction, whether it exists: 3BA02-10 to 3BA02-68,
    # VC02-50) stays with SEFAZ. Mixed into Validator, whose `add`, `in_force?` and
    # `issued_at` it uses.
    module ReferenceRules
      # RV VC02-14 (rej. 321): a return references what it returns, in the header or on each
      # item; and VC02-05 (1010), which VC02-14's observation repeats for a return: never in
      # both. VC02-14 has been checked since 01/09/2026 in homologação (v1.51) and 03/11/2026
      # in production (v1.52). VC02-05 has no date of its own, so the gem asks it from the
      # same day.
      RETURN_REFERENCE_SINCE = {"2" => Time.new(2026, 9, 1, 0, 0, 0, "-03:00"), "1" => Time.new(2026, 11, 3, 0, 0, 0, "-03:00")}.freeze
      # What v1.53 changed, by tpAmb ("Até 09/11/2026" in homologação, 16/11/2026 in
      # production): a return carries one header key only (B25-40, rej. 255; a complement and
      # the credit notes of types 1, 3 and 4 always did), one note per item set but for a
      # return (VC02-30, 1130) and the same issuer on every item of a return (VC02-40, 1193).
      REFERENCE_RULES_SINCE = {"2" => Time.new(2026, 11, 9, 0, 0, 0, "-03:00"), "1" => Time.new(2026, 11, 16, 0, 0, 0, "-03:00")}.freeze
      # RV VC02-20 (rej. 1072): the same key and item referenced twice. NT 2025.002 v1.53
      # says "implementação futura", with no date for either environment, so nothing is
      # checked until one is published (Validator awaiting list, manifest).
      DUPLICATE_ITEM_REFERENCE_SINCE = {"2" => nil, "1" => nil}.freeze
      # The notes that reference one note only in the header (B25-40): a complement, a return
      # and the credit notes of types 01 (fines and interest), 03 (return) and 04 (reduction).
      SINGLE_REFERENCE_CREDIT_NOTES = %w[01 03 04].freeze
      # A return of these CFOPs is exempt from VC02-14 (NT 2013/005 v1.20).
      UNREFERENCED_RETURN_CFOPS = %w[5921 6921].freeze
      # The debit notes VC02-30 leaves alone: unprocessed notes (03) and stock losses (07).
      SEVERAL_DOCUMENT_DEBIT_NOTES = %w[03 07].freeze
      # The series of a Nota Fiscal Avulsa (890 to 899), whose key carries SEFAZ's CNPJ, not
      # the issuer's (the NFA note of VC02-40).
      NFA_SERIES = (890..899)

      private

      # Called once for an NF-e (modelo 55) with its header references.
      def check_note_references(references)
        check_single_reference(references)
        check_return_item_references(references)
        check_item_references_with_header(references)
        check_item_document_count
        check_return_issuers
        check_duplicate_item_references
      end

      # RV B25-40 (rej. 255): one referenced note only. v1.53 added the return, from its day.
      def check_single_reference(references)
        return if references.size < 2

        purpose = @ide["finNFe"].to_s
        label =
          if purpose == "2" then "a complement"
          elsif purpose == "4" && in_force?(REFERENCE_RULES_SINCE) then "a return"
          elsif purpose == "5" && SINGLE_REFERENCE_CREDIT_NOTES.include?(credit_note_type) then "a credit note of type #{credit_note_type}"
          end
        return unless label

        add "ide/NFref: #{label} references one note only in the header, #{references.size} given (RV B25-40, rej. 255); " \
          "a return of several notes names each on its items (det/DFeReferenciado)"
      end

      # RV VC02-14 (rej. 321): a return with no key in the header names it on every item,
      # but for the CFOPs 5921 and 6921.
      def check_return_item_references(references)
        return unless @ide["finNFe"].to_s == "4" && references.empty? && in_force?(RETURN_REFERENCE_SINCE)

        Array(@inf["det"]).each_with_index do |item, index|
          next if item["DFeReferenciado"] || UNREFERENCED_RETURN_CFOPS.include?(item.dig("prod", "CFOP").to_s)

          add "det[#{index + 1}]/DFeReferenciado: a return references the note it returns, in the header (ide/NFref, " \
            "one key) or on every item (RV VC02-14, rej. 321)"
        end
      end

      # RV VC02-05 (rej. 1010), and VC02-14's observation for a return: the header or the
      # items, never both.
      def check_item_references_with_header(references)
        return if references.empty? || !in_force?(RETURN_REFERENCE_SINCE)

        Array(@inf["det"]).each_with_index do |item, index|
          next unless item["DFeReferenciado"]

          add "det[#{index + 1}]/DFeReferenciado: the note references documents in the header (ide/NFref) and on its items; " \
            "give one or the other (RV VC02-05, VC02-14, rej. 1010)"
        end
      end

      # RV VC02-30 (rej. 1130): the items of a note reference one document, but for a return
      # and the debit notes 03 and 07.
      def check_item_document_count
        return if @ide["finNFe"].to_s == "4" || SEVERAL_DOCUMENT_DEBIT_NOTES.include?(@ide["tpNFDebito"].to_s.rjust(2, "0"))
        return unless in_force?(REFERENCE_RULES_SINCE)

        first = nil
        item_references.each do |number, key, _|
          first ||= key
          next if key == first

          add "det[#{number}]/DFeReferenciado/chaveAcesso: the items of this note reference more than one document, " \
            "#{first} and #{key} (RV VC02-30, rej. 1130)"
        end
      end

      # RV VC02-40 (rej. 1193): every item of a return references the same issuer (CNPJ base
      # or CPF, the first 8 characters of the key's issuer field). An NFA's key carries
      # SEFAZ's CNPJ, so its issuer is left to SEFAZ.
      def check_return_issuers
        return unless @ide["finNFe"].to_s == "4" && in_force?(REFERENCE_RULES_SINCE)

        first = nil
        item_references.each do |number, key, _|
          next if NFA_SERIES.cover?(key[22, 3].to_i)

          first ||= key
          next if key[6, 8] == first[6, 8]

          add "det[#{number}]/DFeReferenciado/chaveAcesso: a return references the same issuer on every item; this key's " \
            "(#{key[6, 8]}) isn't the first item's (#{first[6, 8]}) (RV VC02-40, rej. 1193)"
        end
      end

      # RV VC02-20 (rej. 1072): a key and item referenced more than once. Without nItem on
      # both, the same key may be on several items (v1.53 made nItem optional for a return),
      # so only a repeated pair counts.
      def check_duplicate_item_references
        return unless in_force?(DUPLICATE_ITEM_REFERENCE_SINCE)

        seen = {}
        item_references.each do |number, key, referenced_item|
          next if referenced_item.nil?

          pair = [key, referenced_item]
          if seen[pair]
            add "det[#{number}]/DFeReferenciado: item #{referenced_item} of #{key} is already referenced by det[#{seen[pair]}] " \
              "(RV VC02-20, rej. 1072)"
          end
          seen[pair] ||= number
        end
      end

      # [item number, referenced key, referenced item] of each item that references one.
      def item_references
        Array(@inf["det"]).each_with_index.filter_map do |item, index|
          group = item["DFeReferenciado"] or next
          key = group["chaveAcesso"].to_s
          next if key.length != 44

          [index + 1, key, group["nItem"]&.to_s]
        end
      end

      # The year of every note a return or a complement references, from the AAMM of its key,
      # in the header or on the items.
      def referenced_years
        keys = Array(@ide["NFref"]).filter_map { |reference| reference["refNFe"] || reference["refNFeSig"] if reference.is_a?(Hash) }
        keys += item_references.map { |_, key, _| key }
        keys.filter_map { |key| 2000 + key[2, 2].to_i if key.to_s.match?(/\A\d{6}/) }
      end

      # RV UB12-10, exception 1 (NT 2025.002 v1.53): a return or a complement that references
      # a note issued before 2027 needs no IBS/CBS group. The note that does need it is one
      # that references notes of 2027 on: all of them, since a mix of both is left to SEFAZ,
      # which says "a note issued before 2027". One that references none the gem can read
      # (a paper note, or none) keeps the exception.
      def references_only_from_ibs_cbs_year?
        years = referenced_years
        years.any? && years.all? { |year| year >= Rates::CBS_CHARGED_SINCE }
      end
    end
  end
end
