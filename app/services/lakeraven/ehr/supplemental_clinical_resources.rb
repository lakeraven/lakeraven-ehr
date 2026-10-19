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
      WireAllergyBatch = Struct.new(:records, :dropped_count, :assessed, :nka, keyword_init: true)
      private_constant :WireAllergyBatch

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
            nka: wire.nka
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
          assessed, nka, rows = wire_allergy_reply(dfn)
          kept, dropped = split_owned_wire_allergies(rows, dfn)
          WireAllergyBatch.new(
            records: kept, dropped_count: dropped, assessed: assessed, nka: nka
          )
        end

        # for_patient is what stubs replace. When that call is the gateway's,
        # the rows are the assessment's own array and the flags are real;
        # a stubbed list did not come from ORQQAL and cannot prove NKA.
        def wire_allergy_reply(dfn)
          begin_wire_assessment_capture
          rows = Array(AllergyIntolerance.for_patient(dfn))
          assessed, nka = assessment_flags(assessment_state_for(rows))
          [ assessed, nka, rows ]
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
          return [ false, false ] unless state.is_a?(Hash)

          [ state[:assessed] == true, state[:nka] == true ]
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

        # merge's kept rows, plus how many dropped repeats were a different
        # allergy. Observations still use merge: a repeated id there is
        # dropped and uncounted. Two rows are the same allergy when both
        # carry an allergen code and the codes are equal after strip, or
        # when at least one has no code and the names are equal after
        # strip, downcase, and collapsed internal whitespace. A repeat
        # counts when the codes differ, the names differ, a name needed for
        # that comparison is blank, or a row does not respond to allergen
        # or allergen_code. The same allergy stated twice is not a hole
        # in the list.
        def merge_allergies(wire, supplemental)
          [ merge(wire, supplemental), differing_allergy_drops(wire, supplemental) ]
        end

        def differing_allergy_drops(wire, supplemental)
          seen = {}
          drops = 0
          (wire + supplemental).each do |resource|
            id = merge_ien(resource)
            next if id.empty?

            prior = seen[id]
            if prior
              drops += 1 if differing_allergy?(prior, resource)
            else
              seen[id] = resource
            end
          end
          drops
        end

        def merge_ien(resource)
          resource.respond_to?(:ien) ? resource.ien.to_s.strip : ""
        end

        def differing_allergy?(kept, candidate)
          return true unless reads_allergen_identity?(kept) && reads_allergen_identity?(candidate)

          left_code = stripped_allergen_code(kept)
          right_code = stripped_allergen_code(candidate)
          return left_code != right_code if left_code && right_code

          normalized_allergen_names_differ?(kept, candidate)
        end

        def reads_allergen_identity?(resource)
          resource.respond_to?(:allergen) && resource.respond_to?(:allergen_code)
        end

        def stripped_allergen_code(resource)
          resource.allergen_code.to_s.strip.presence
        end

        def normalized_allergen_names_differ?(kept, candidate)
          left = normalized_allergen_name(kept)
          right = normalized_allergen_name(candidate)
          left.blank? || right.blank? || left != right
        end

        def normalized_allergen_name(resource)
          resource.allergen.to_s.squish.downcase
        end
      end
    end
  end
end
