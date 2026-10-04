# frozen_string_literal: true

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
          wire + owned_by(dfn, Lakeraven::EHR.configuration.supplemental_observations_provider)
        end

        def merged_allergy_intolerances_for_patient(dfn)
          wire_allergies(dfn) + owned_by(dfn, Lakeraven::EHR.configuration.supplemental_allergy_intolerances_provider)
        end

        # The wire returns ORQQAL LIST rows as hashes (ien, allergen, severity,
        # signs) while a supplemental provider returns model instances. Both
        # sides are normalized to models here so one serializer renders them and
        # a supplemental row cannot be told from a wire row by its shape.
        def wire_allergies(dfn)
          Array(AllergyIntolerance.for_patient(dfn)).map do |row|
            next row unless row.is_a?(Hash)

            AllergyIntolerance.new(
              ien: row[:ien],
              patient_dfn: dfn.to_s,
              allergen: row[:allergen],
              severity: row[:severity],
              reaction: row[:signs] || row[:reaction],
              category: row[:category],
              allergen_code: row[:allergen_code]
            )
          end
        end

        private

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
