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
      class << self
        def merged_observations_for_patient(dfn)
          merge(wire_observations(dfn),
                owned_by(dfn, Lakeraven::EHR.configuration.supplemental_observations_provider,
                         Observation))
        end

        def merged_allergy_intolerances_for_patient(dfn)
          merge(wire_allergies(dfn),
                owned_by(dfn, Lakeraven::EHR.configuration.supplemental_allergy_intolerances_provider,
                         AllergyIntolerance))
        end

        private

        # Observation.from_vital_hashes STAMPS the requested DFN and discards
        # whatever the row said, so a row naming another patient has to be
        # rejected BEFORE conversion -- afterwards the evidence is gone.
        def wire_observations(dfn)
          rows = Array(ObservationGateway.for_patient(dfn)).select { |row| wire_row_owned?(row, dfn) }
          Observation.from_vital_hashes(rows, patient_dfn: dfn)
        end

        def wire_allergies(dfn)
          Array(AllergyIntolerance.for_patient(dfn)).filter_map do |row|
            next unless wire_row_owned?(row, dfn)

            row.is_a?(Hash) ? allergy_from_wire(row, dfn) : verified(row, dfn)
          end
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

        # nil / [] / a non-array all mean "no supplemental rows" -- ordinary
        # states for a provider, not failures. A provider that RAISES is a
        # failure and is surfaced rather than rescued into an empty slice, which
        # would be indistinguishable from configuring no provider at all.
        # `expected` is the resource type this provider is declared to supply.
        # Ownership alone is not enough: an AllergyIntolerance returned by the
        # OBSERVATION provider owns the right patient and would be serialized
        # into an Observation bundle, breaking the endpoint's resource-type
        # contract. An object of no known type would also fail later, outside
        # the provider-error wrapper, where the failure no longer names a cause.
        def owned_by(dfn, provider, expected)
          return [] if provider.nil?

          produced = begin
            provider.call(dfn.to_s)
          rescue SupplementalProviderError
            raise
          rescue => e
            raise SupplementalProviderError,
              "supplemental provider failed for patient #{dfn}: #{e.class}: #{e.message}"
          end

          return [] unless produced.is_a?(Array)

          produced.filter_map do |resource|
            next unless resource.is_a?(expected)

            owner = stated_owner(resource)
            verified(resource, dfn) if owner && same_patient?(owner, dfn)
          end
        end

        # The ownership check and the serialization are separate reads, so an
        # object whose patient_dfn changes in between -- a provider handing back
        # a mutable object it still holds -- could pass the check and then
        # serialize a foreign reference. Serve a copy carrying the OWNER WE
        # VERIFIED, so what was checked is what is rendered.
        def verified(resource, dfn)
          return resource unless resource.respond_to?(:patient_dfn=)

          copy = resource.dup
          copy.patient_dfn = canonical(dfn)
          copy
        end

        def stated_owner(row)
          value = row.is_a?(Hash) ? field(row, :patient_dfn) : (row.respond_to?(:patient_dfn) ? row.patient_dfn : nil)
          value.to_s.strip.presence
        end

        # Hashes reach here from several RPC mappings; some use symbol keys and
        # some string keys. Reading only one kind treats a stated owner as absent
        # and lets the row be adopted by whichever patient was asked for.
        def field(row, key)
          return nil unless row.is_a?(Hash)

          row[key].nil? ? row[key.to_s] : row[key]
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

        def canonical(value)
          numeric = value.to_s.strip
          return "" unless numeric.match?(/\A\d+\z/)

          i = numeric.to_i
          i.positive? ? i.to_s : ""
        end

        # A FHIR searchset must not carry two entries with one id: a client
        # keying on id either breaks or shows a false duplicate. The wire row
        # wins as the system of record. A blank id is not an identity, so blanks
        # never collide with each other, and supplemental ids join the seen set
        # so two supplemental rows cannot both claim one id.
        def merge(wire, supplemental)
          seen = Set.new
          (wire + supplemental).select do |resource|
            id = resource.respond_to?(:ien) ? resource.ien.to_s.strip : ""
            next true if id.empty?

            seen.add?(id) ? true : false
          end
        end
      end
    end
  end
end
