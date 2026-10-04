# frozen_string_literal: true

require "set"
module Lakeraven
  module EHR
    # Merges wire-sourced clinical resources with a deployment's supplemental
    # provider output, enforcing the patient compartment on the supplemental
    # slice.
    #
    # The wire slice is already patient-scoped by the RPC. The supplemental
    # slice is not scoped by anything until here: the provider is deployment
    # code and can return any resource, including another patient's. So every
    # supplemental row is checked against the requested DFN, and a row with no
    # patient_dfn at all is dropped -- an unattributable clinical resource
    # cannot be shown to be the requested patient's.
    class SupplementalClinicalResources
      class << self
        def merged_observations_for_patient(dfn)
          wire = Observation.from_vital_hashes(Observation.for_patient(dfn), patient_dfn: dfn)
          merge(wire, owned_by(dfn, Lakeraven::EHR.configuration.supplemental_observations_provider))
        end

        def merged_allergy_intolerances_for_patient(dfn)
          merge(wire_allergies(dfn),
                owned_by(dfn, Lakeraven::EHR.configuration.supplemental_allergy_intolerances_provider))
        end

        # The wire returns ORQQAL LIST rows as hashes (ien, allergen, severity,
        # signs) while a supplemental provider returns model instances. Both
        # sides are normalized to models here so one serializer renders them and
        # a supplemental row cannot be told from a wire row by its shape.
        # A wire row that does NOT state a patient is taken as the requested
        # patient's: the RPC was asked for that patient and is the system of
        # record. A row that DOES state a different patient is dropped -- its own
        # statement wins over the question that was asked, because a mis-scoped
        # row (broker bug, stale cache, bad LIST) would otherwise be served as
        # this patient's data and be indistinguishable from it.
        def wire_allergies(dfn)
          Array(AllergyIntolerance.for_patient(dfn)).filter_map do |row|
            resource = row.is_a?(Hash) ? allergy_from_wire(row, dfn) : row
            next resource unless resource.respond_to?(:patient_dfn)

            resource if resource.patient_dfn.to_s == dfn.to_s
          end
        end

        # The one place a wire allergy row becomes a model, so the FHIR search
        # and the chart bundle cannot disagree about the same row.
        #
        # Two readings of ORQQAL LIST exist in this codebase: the mapped surface
        # names IEN^ALLERGEN^SEVERITY^SIGNS, while the chart builder documented
        # ALLERGEN^REACTION^SEVERITY with no IEN. Rather than pick one and be
        # silently wrong on the other, both key names are accepted and the id
        # falls back to a deterministic derivation when the row carries none.
        def allergy_from_wire(row, dfn)
          AllergyIntolerance.new(
            ien: row[:ien].to_s.presence || "allergy-#{dfn}-#{row[:allergen].to_s.parameterize}",
            # The row's own patient when it states one. Stamping the requested
            # DFN unconditionally would launder a mis-scoped row into this
            # patient's compartment.
            patient_dfn: row[:patient_dfn].presence&.to_s || dfn.to_s,
            allergen: row[:allergen],
            severity: row[:severity],
            reaction: row[:signs].presence || row[:reaction],
            category: row[:category],
            allergen_code: row[:allergen_code],
            clinical_status: row[:clinical_status].presence || "active",
            criticality: row[:criticality].presence ||
                         (row[:severity].to_s.downcase == "severe" ? "high" : nil)
          )
        end

        private

        # A FHIR searchset must not carry two entries with the same id: a client
        # keying on id either breaks or shows a false duplicate. The wire row
        # wins -- it is the system of record, and a supplemental provider must
        # not be able to shadow it.
        def merge(wire, supplemental)
          seen = wire.map { |r| r.ien.to_s }.to_set
          wire + supplemental.reject { |r| seen.include?(r.ien.to_s) }
        end

        # nil / [] / a non-array all mean "no supplemental rows" -- those are
        # ordinary states for a provider, not failures. A provider that RAISES
        # is a failure and is surfaced.
        def owned_by(dfn, provider)
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

          produced.select do |resource|
            owner = resource.respond_to?(:patient_dfn) ? resource.patient_dfn : nil
            owner.present? && owner.to_s == dfn.to_s
          end
        end
      end
    end
  end
end
