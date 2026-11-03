# frozen_string_literal: true

require "set"

module Lakeraven
  module EHR
    # Merges wire-sourced clinical resources with a deployment's supplemental
    # provider output, enforcing the patient compartment on BOTH slices.
    #
    # The wire slice is queried per patient, but a row that states a patient of
    # its own is believed over the question that was asked: a mis-scoped row
    # (broker bug, stale cache, bad LIST) would otherwise be served as the
    # requested patient's and be indistinguishable from it.
    #
    # The supplemental slice is deployment-supplied Ruby and is scoped by nothing
    # until here, so every row is checked and a row that cannot state an owner is
    # dropped -- an unattributable clinical resource cannot be shown to be this
    # patient's.
    class SupplementalClinicalResources
      WireAllergyBatch = Struct.new(:records, :dropped_count, :assessed, :nka, :conflict, keyword_init: true)
      # Not a placeholder and not ASCII digits. Never an identity that can match.
      MALFORMED_ALLERGEN_CODE = :malformed
      private_constant :WireAllergyBatch, :MALFORMED_ALLERGEN_CODE

      class << self
        def merged_observations_for_patient(dfn)
          merge(wire_observations(dfn),
                owned_by(dfn, Lakeraven::EHR.configuration.supplemental_observations_provider,
                         Observation))
        end

        # The raw wire vitals, compartment-checked. Observation models are built
        # from these rows; reading them straight from the gateway skipped the
        # ownership check the FHIR paths apply.
        def wire_vital_rows_for_patient(dfn)
          Array(ObservationGateway.for_patient(dfn)).select { |row| wire_row_owned?(row, dfn) }
        end

        def merged_allergy_intolerances_for_patient(dfn)
          allergy_intolerance_reading_for_patient(dfn)
        end

        # Rows plus ORQQAL's assessed/nka flags and how many rows were not
        # kept: a wire row naming another patient, a supplemental row owned_by
        # refused (no owner, another patient, the wrong class), a supplemental
        # result that was not an Array, or a repeated ien that is a different
        # allergy. The merged list is what FHIR search returns; the count is
        # what stops that hole reading as "none recorded".
        def allergy_intolerance_reading_for_patient(dfn)
          wire = wire_allergy_batch(dfn)
          supplemental, supplemental_dropped = supplemental_allergy_slice(dfn)
          records, differing_drops = merge_allergies(wire.records, supplemental)
          AllergyIntoleranceReading.new(
            records,
            dropped_count: wire.dropped_count + supplemental_dropped + differing_drops,
            assessed: wire.assessed,
            nka: wire.nka,
            conflict: wire.conflict
          )
        end

        private

        # Observation.from_vital_hashes STAMPS the requested DFN and discards
        # whatever the row said, so a row naming another patient has to be
        # rejected BEFORE conversion -- afterwards the evidence is gone.
        def wire_observations(dfn)
          Observation.from_vital_hashes(wire_vital_rows_for_patient(dfn), patient_dfn: dfn)
        end

        # [kept rows, dropped count]. The rows are what owned_by would return;
        # the count is the hole those callers do not see.
        def supplemental_allergy_slice(dfn)
          owned_slice(
            dfn,
            Lakeraven::EHR.configuration.supplemental_allergy_intolerances_provider,
            AllergyIntolerance
          )
        end

        def wire_allergy_batch(dfn)
          assessed, nka, conflict, rows = wire_allergy_reply(dfn)
          kept, dropped = split_owned_wire_allergies(rows, dfn)
          WireAllergyBatch.new(
            records: kept, dropped_count: dropped, assessed: assessed, nka: nka, conflict: conflict
          )
        end

        # for_patient is what stubs replace. When that call is the gateway's,
        # the rows are the assessment's own array and the flags are real;
        # a stubbed list did not come from ORQQAL and cannot prove NKA.
        def wire_allergy_reply(dfn)
          begin_wire_assessment_capture
          rows = Array(AllergyIntolerance.for_patient(dfn))
          [ *assessment_flags(assessment_state_for(rows)), rows ]
        ensure
          end_wire_assessment_capture
        end

        def assessment_state_for(rows)
          gateway = AllergyIntolerance.gateway
          return unless gateway.respond_to?(:take_assessment)

          gateway.take_assessment(rows)
        end

        def begin_wire_assessment_capture
          gateway = AllergyIntolerance.gateway
          gateway.begin_assessment_capture! if gateway.respond_to?(:begin_assessment_capture!)
        end

        def end_wire_assessment_capture
          gateway = AllergyIntolerance.gateway
          gateway.end_assessment_capture! if gateway.respond_to?(:end_assessment_capture!)
        end

        def assessment_flags(state)
          return [ false, false, false ] unless state.is_a?(Hash)

          [ state[:assessed] == true, state[:nka] == true, state[:conflict] == true ]
        end

        # A dropped wire row is not this patient's allergy, and it is not
        # evidence the list was empty. The count stays on the reading so
        # display cannot turn the hole into "none recorded".
        def split_owned_wire_allergies(rows, dfn)
          kept = []
          dropped = 0
          Array(rows).each do |row|
            record = kept_wire_allergy(row, dfn)
            if record
              kept << record
            else
              dropped += 1
            end
          end
          [ kept, dropped ]
        end

        def kept_wire_allergy(row, dfn)
          return unless wire_row_owned?(row, dfn)

          row.is_a?(Hash) ? allergy_from_wire(row, dfn) : verified(row, dfn)
        end

        # A wire row with no stated owner is the requested patient's: the RPC was
        # asked for that patient and is the system of record. One that states a
        # different owner is not.
        def wire_row_owned?(row, dfn)
          owner = stated_owner(row)
          owner.nil? || same_patient?(owner, dfn)
        end

        def allergy_from_wire(row, dfn)
          verified(
            AllergyIntolerance.new(
              ien: field(row, :ien).to_s.presence ||
                   "allergy-#{canonical(dfn)}-#{field(row, :allergen).to_s.parameterize}",
              allergen: field(row, :allergen),
              severity: field(row, :severity),
              # Two readings of ORQQAL LIST exist in this codebase: the mapped
              # surface names IEN^ALLERGEN^SEVERITY^SIGNS, while the chart builder
              # documented ALLERGEN^REACTION^SEVERITY with no IEN. Both key names
              # are accepted rather than picking one and being silently wrong on
              # the other.
              reaction: field(row, :signs).presence || field(row, :reaction),
              category: field(row, :category),
              allergen_code: field(row, :allergen_code),
              clinical_status: field(row, :clinical_status).presence || "active",
              criticality: field(row, :criticality).presence ||
                           (field(row, :severity).to_s.downcase == "severe" ? "high" : nil)
            ),
            dfn
          )
        end

        # Kept rows only. Observations and the other merged_* callers see this
        # array and nothing else — a non-array result is still [], and a row
        # that fails the checks below is still absent. The allergy reading
        # uses owned_slice so those holes are counted.
        def owned_by(dfn, provider, expected)
          kept, = owned_slice(dfn, provider, expected)
          kept
        end

        # [kept, dropped]. No provider is an empty slice: nothing was
        # configured, so there is no hole. [] is an answer that named no rows.
        # nil is that same answer — a supplemental provider's contract for
        # "no rows for this patient" — so it is zero rows and zero drops.
        # Any other non-Array did not answer; the rows we can show are still
        # none, and the drop count refuses verified absence over that hole.
        def owned_slice(dfn, provider, expected)
          return [ [], 0 ] if provider.nil?

          produced = supplemental_provider_result(dfn, provider)
          return [ [], 0 ] if produced.nil?
          return [ [], 1 ] unless produced.is_a?(Array)

          split_owned_supplemental(produced, dfn, expected)
        end

        def supplemental_provider_result(dfn, provider)
          provider.call(dfn.to_s)
        rescue SupplementalProviderError
          raise
        rescue => e
          raise SupplementalProviderError,
            "supplemental provider failed for patient #{dfn}: #{e.class}: #{e.message}"
        end

        def split_owned_supplemental(produced, dfn, expected)
          kept = []
          dropped = 0
          produced.each do |resource|
            record = kept_supplemental(resource, dfn, expected)
            if record
              kept << record
            else
              dropped += 1
            end
          end
          [ kept, dropped ]
        end

        # `expected` is the resource type this provider is declared to supply.
        # Ownership alone is not enough: an AllergyIntolerance returned by the
        # OBSERVATION provider owns the right patient and would be serialized
        # into an Observation bundle, breaking the endpoint's resource-type
        # contract. An object of no known type would also fail later, outside
        # the provider-error wrapper, where the failure no longer names a cause.
        #
        # instance_of?, not is_a?: a subclass can override to_fhir to emit
        # another resource type, and an object can override is_a? to pass a
        # check it should fail. Only the engine's own model is accepted.
        def kept_supplemental(resource, dfn, expected)
          return unless resource.instance_of?(expected)

          owner = stated_owner(resource)
          verified(resource, dfn) if owner && same_patient?(owner, dfn)
        end

        # The ownership check and the serialization are separate reads, so an
        # object whose patient_dfn changes in between -- a provider handing back
        # a mutable object it still holds -- could pass the check and then
        # serialize a foreign reference. Serve a copy carrying the OWNER WE
        # VERIFIED, so what was checked is what is rendered.
        def verified(resource, dfn)
          return nil unless resource.respond_to?(:patient_dfn=)

          copy = resource.dup
          copy.patient_dfn = canonical(dfn)
          # Prove the assignment took, so a setter that ignored its argument
          # could not leave the original owner in place and serialize it after
          # passing the check.
          #
          # UNREACHABLE while the instance_of? check above holds: only this
          # engine's own models get here, and their patient_dfn= is an ordinary
          # attribute writer. No test covers it and a mutation removing it
          # survives, so it is not a verified guard -- it is here so that
          # loosening instance_of? later fails closed instead of open.
          return nil unless same_patient?(copy.patient_dfn, dfn)

          copy
        end

        def stated_owner(row)
          value = row.is_a?(Hash) ? field(row, :patient_dfn) : (row.respond_to?(:patient_dfn) ? row.patient_dfn : nil)
          value.to_s.strip.presence
        end

        # Hashes reach here from several RPC mappings; some use symbol keys and
        # some string keys. Reading only one kind treats a stated owner as absent
        # and lets the row be adopted by whichever patient was asked for.
        # The FIRST PRESENT value across both key kinds. Preferring a non-nil
        # symbol value let a blank one mask a stated string-keyed owner --
        # { patient_dfn: "", "patient_dfn" => "2" } read as ownerless and was
        # adopted by whichever patient was asked for.
        def field(row, key)
          return nil unless row.is_a?(Hash)

          [ row[key], row[key.to_s] ].find { |v| v.to_s.strip.present? } || row[key] || row[key.to_s]
        end

        # PatientRepository.find resolves a DFN with to_i, so 1, "1", "01" and
        # " 1 " are the same patient. Comparing the raw strings would exclude a
        # row that is genuinely this patient's because it was written "01".
        # Non-positive values are not patients at all (same rejection as the
        # repository) and never match.
        def same_patient?(a, b)
          left = canonical(a)
          right = canonical(b)
          left.present? && left == right
        end

        # Same rule as Patient.canonical_dfn, so an audit of the patient
        # this row was kept for cannot spell the dfn a different way.
        def canonical(value)
          Patient.canonical_dfn(value).to_s
        end

        # A FHIR searchset must not carry two entries with one id: a client
        # keying on id either breaks or shows a false duplicate. The wire row
        # wins as the system of record. A blank id is not an identity, so blanks
        # never collide with each other, and supplemental ids join the seen set
        # so two supplemental rows cannot both claim one id.
        def merge(wire, supplemental)
          seen = Set.new
          (wire + supplemental).select do |resource|
            id = merge_ien(resource)
            next true if id.empty?

            seen.add?(id) ? true : false
          end
        end

        # merge's kept rows stay unchanged: the first row for an ien wins.
        # Observations still use merge, where a repeated id is dropped and
        # uncounted. The pair is those kept rows plus how many dropped
        # repeats were a different allergy.
        #
        # Two rows sharing an ien are the same allergy only when their
        # normalised names (to_s, strip, downcase, squish) are both
        # non-blank and equal and, when both rows carry a valid code, the
        # codes are equal. A name whose bytes are not valid UTF-8 is not
        # normalised: the check is a duplicate forced to UTF-8, so a binary
        # string that is not valid UTF-8 fails it too. That identity is
        # non-comparable. It matches no row, including the same bytes, so
        # it counts as dropped, and it does not raise. An ASCII-8BIT wire
        # string whose bytes are valid UTF-8 is still normalised in that
        # encoding, so its match does not change. Each allergen_code is
        # normalised first: NFKC (compatibility digits, including
        # full-width, become ASCII), then
        # leading and trailing Unicode space is removed with [[:space:]]
        # and \p{Space} (NBSP included), then an integral decimal (ASCII
        # digits, a dot, and zeros) becomes those integer digits. Blank,
        # UNK in any case, and all zeros are placeholders and count as no
        # code. A valid code is ASCII digits with leading zeros removed.
        # Any other code is malformed: that row is a different allergy
        # whatever the other row holds. Differing spellings, a blank name,
        # an unreadable name, a code-only row, different valid codes, or a
        # row that does not respond to allergen and allergen_code also
        # count as dropped. The same allergy stated twice is not a hole.
        #
        # Per ien only the distinct identities are kept, each
        # [normalised_name, valid_code_or_nil]. A repeat whose identity was
        # already seen is the same allergy and costs a constant-time
        # lookup. That shortcut applies only to a comparable identity: a
        # non-blank readable name and a code that is not malformed. A
        # malformed code or an unreadable name is never that identity, so
        # the shortcut cannot treat it as already seen. A new identity is
        # compared only against the distinct ones kept for that ien.
        def merge_allergies(wire, supplemental)
          [ merge(wire, supplemental), differing_allergy_drops(wire, supplemental) ]
        end

        def differing_allergy_drops(wire, supplemental)
          seen = {}
          drops = 0
          (wire + supplemental).each do |resource|
            id = merge_ien(resource)
            next if id.empty?

            drops += differing_allergy_drop(seen, id, resource)
          end
          drops
        end

        def differing_allergy_drop(seen, id, resource)
          identities = (seen[id] ||= Set.new)
          identity = allergen_identity(resource)
          return 0 if seen_same_allergy?(identities, identity)

          differed = identities.any? { |prior| differing_allergy?(prior, identity) }
          identities.add(identity)
          differed ? 1 : 0
        end

        # Blank names, unreadable names, malformed codes, and rows that
        # cannot state an allergen identity are never the same allergy,
        # including a repeat of that same text. The shortcut matches only a
        # comparable identity already kept for the ien, so a malformed code
        # or an unreadable name cannot hit it.
        def seen_same_allergy?(identities, identity)
          comparable_allergen_identity?(identity) && identities.include?(identity)
        end

        def comparable_allergen_identity?(identity)
          identity.is_a?(Array) && identity.first.present? && !malformed_allergen_identity?(identity)
        end

        # The symbol itself, or a pair whose code slot is that symbol.
        # Either shape must miss the per-ien shortcut.
        def malformed_allergen_identity?(identity)
          malformed_allergen_code?(identity) ||
            (identity.is_a?(Array) && malformed_allergen_code?(identity[1]))
        end

        def malformed_allergen_code?(code)
          code == MALFORMED_ALLERGEN_CODE
        end

        def allergen_identity(resource)
          return unless reads_allergen_identity?(resource)

          code = classified_allergen_code(resource.allergen_code)
          return code if malformed_allergen_code?(code)

          [ normalized_allergen_name(resource), code ]
        end

        # prior and candidate are [normalised_name, valid_code_or_nil], or
        # a non-array when the row cannot be compared: it does not respond
        # to allergen and allergen_code, or its code is malformed. A blank
        # or unreadable name is an array and is still not comparable. A
        # non-comparable row differs from every row, including itself.
        def differing_allergy?(prior, candidate)
          return true unless comparable_allergen_identity?(prior) && comparable_allergen_identity?(candidate)

          prior_name, prior_code = prior
          candidate_name, candidate_code = candidate
          return true if prior_name.blank? || candidate_name.blank? || prior_name != candidate_name
          return true if malformed_allergen_code?(prior_code) || malformed_allergen_code?(candidate_code)

          prior_code.present? && candidate_code.present? && prior_code != candidate_code
        end

        def merge_ien(resource)
          resource.respond_to?(:ien) ? resource.ien.to_s.strip : ""
        end

        def reads_allergen_identity?(resource)
          resource.respond_to?(:allergen) && resource.respond_to?(:allergen_code)
        end

        # Placeholder (nil), canonical ASCII digits, or MALFORMED_ALLERGEN_CODE.
        # Nil counts as no code. Malformed matches nothing.
        def classified_allergen_code(raw)
          text = normalized_allergen_code_text(raw)
          return MALFORMED_ALLERGEN_CODE if text.nil?
          return if placeholder_allergen_code?(text)
          return MALFORMED_ALLERGEN_CODE unless text.match?(/\A[0-9]+\z/)

          text.sub(/\A0+/, "")
        end

        # NFKC, then trim Unicode spaces, then an integral decimal (digits,
        # ".", zeros) becomes those integer digits. Nil when the bytes are
        # not valid UTF-8: that code cannot be read, so it is malformed.
        def normalized_allergen_code_text(raw)
          text = nfkc_allergen_code(raw.to_s)
          return if text.nil?

          strip_unicode_space(text).sub(/\A([0-9]+)\.0+\z/, '\1')
        end

        def nfkc_allergen_code(text)
          utf8 = text.dup.force_encoding(Encoding::UTF_8)
          return unless utf8.valid_encoding?

          utf8.unicode_normalize(:nfkc)
        rescue ArgumentError, EncodingError
          nil
        end

        # [[:space:]] and \p{Space} are one set here, and both include NBSP
        # plus the separators String#strip leaves in place.
        def strip_unicode_space(text)
          text.gsub(/\A[[:space:]\p{Space}]+|[[:space:]\p{Space}]+\z/, "")
        end

        # Blank, UNK in any case, or all ASCII zeros. Not a code.
        def placeholder_allergen_code?(text)
          text.empty? || text.match?(/\Aunk\z/i) || text.match?(/\A0+\z/)
        end

        # to_s, strip, downcase, squish. Nil when the bytes are not valid
        # UTF-8: that name cannot be read, so the identity is non-comparable,
        # the same way a blank name is. The check is a duplicate forced to
        # UTF-8, which also rejects a binary string that is not valid UTF-8.
        # The original string is what gets normalised, so an ASCII-8BIT wire
        # string of valid UTF-8 bytes keeps its encoding and its match.
        def normalized_allergen_name(resource)
          text = resource.allergen.to_s
          utf8 = text.dup.force_encoding(Encoding::UTF_8)
          return unless utf8.valid_encoding?

          text.strip.downcase.squish
        rescue ArgumentError, EncodingError
          nil
        end
      end
    end
  end
end
