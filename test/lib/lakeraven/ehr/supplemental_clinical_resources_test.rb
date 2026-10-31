# frozen_string_literal: true

require "test_helper"

# Contract (builder implements; do not edit these tests):
#
#   Lakeraven::EHR.configuration.supplemental_observations_provider
#   Lakeraven::EHR.configuration.supplemental_allergy_intolerances_provider
#     optional callables: dfn -> Array<Observation> / Array<AllergyIntolerance>
#
#   Lakeraven::EHR::SupplementalClinicalResources.merged_observations_for_patient(dfn)
#   Lakeraven::EHR::SupplementalClinicalResources.merged_allergy_intolerances_for_patient(dfn)
#     merge wire RPC results with filtered supplemental provider output;
#     return model instances ready for the existing FHIR serializers.
#
module Lakeraven
  module EHR
    class SupplementalClinicalResourcesTest < ActiveSupport::TestCase
      include SupplementalProviderConfigHelper

      REQUESTED_DFN = "1"
      FOREIGN_DFN = "2"

      setup do
        assert_respond_to Lakeraven::EHR.configuration, :supplemental_observations_provider=
        assert_respond_to Lakeraven::EHR.configuration, :supplemental_allergy_intolerances_provider=
        assert_respond_to SupplementalClinicalResources, :merged_observations_for_patient
        assert_respond_to SupplementalClinicalResources, :merged_allergy_intolerances_for_patient
      end

      # -- Observations: patient compartment on supplemental slice ---------------

      test "merged_observations drops every supplemental row for another patient" do
        # Catches returning provider output without patient_dfn filtering.
        foreign = laboratory_observation(ien: "foreign-lab", patient_dfn: FOREIGN_DFN, code: "4548-4")

        with_supplemental_providers(
          observations: ->(_dfn) { [ foreign ] }
        ) do
          results = SupplementalClinicalResources.merged_observations_for_patient(REQUESTED_DFN)
          assert results.any?, "expected wire-sourced observations for patient 1"
          ids = results.map(&:ien)
          refute_includes ids, "foreign-lab"
        end
      end

      test "merged_observations keeps owned supplemental rows and drops foreign ones in a mix" do
        # Catches partial filtering (foreign rows slipping through when any owned row exists).
        owned = laboratory_observation(ien: "owned-lab", patient_dfn: REQUESTED_DFN, code: "4548-4")
        foreign = laboratory_observation(ien: "foreign-lab", patient_dfn: FOREIGN_DFN, code: "2339-0")

        with_supplemental_providers(
          observations: ->(_dfn) { [ owned, foreign ] }
        ) do
          results = SupplementalClinicalResources.merged_observations_for_patient(REQUESTED_DFN)
          assert results.any?, "expected merged observations to be non-empty"
          ids = results.map(&:ien)
          assert_includes ids, "owned-lab"
          refute_includes ids, "foreign-lab"
        end
      end

      test "merged_observations treats nil supplemental provider output as no supplemental rows" do
        # Catches NoMethodError or corrupt merges when the callable returns nil.
        baseline = SupplementalClinicalResources.merged_observations_for_patient(REQUESTED_DFN)
        assert baseline.any?, "expected wire-only baseline observations"

        with_supplemental_providers(observations: ->(_dfn) { nil }) do
          results = SupplementalClinicalResources.merged_observations_for_patient(REQUESTED_DFN)
          assert_equal baseline.map(&:ien).sort, results.map(&:ien).sort
        end
      end

      test "merged_observations treats empty supplemental provider output as no supplemental rows" do
        # Catches spurious extra rows when the provider returns [].
        baseline = SupplementalClinicalResources.merged_observations_for_patient(REQUESTED_DFN)
        assert baseline.any?, "expected wire-only baseline observations"

        with_supplemental_providers(observations: ->(_dfn) { [] }) do
          results = SupplementalClinicalResources.merged_observations_for_patient(REQUESTED_DFN)
          assert_equal baseline.map(&:ien).sort, results.map(&:ien).sort
        end
      end

      test "merged_observations treats non-array supplemental provider output as no supplemental rows" do
        # Catches splat/concat bugs when the provider returns a scalar or Hash.
        baseline = SupplementalClinicalResources.merged_observations_for_patient(REQUESTED_DFN)
        assert baseline.any?, "expected wire-only baseline observations"

        with_supplemental_providers(observations: ->(_dfn) { "not-an-array" }) do
          results = SupplementalClinicalResources.merged_observations_for_patient(REQUESTED_DFN)
          assert_equal baseline.map(&:ien).sort, results.map(&:ien).sort
        end
      end

      test "configured observations provider that raises does not fail silently as empty supplemental" do
        # Catches rescue-to-[] which hides a broken deployment adapter.
        # When a provider is configured, its failure must be visible — not identical to "no provider".
        with_supplemental_providers(
          observations: ->(_dfn) { raise SupplementalProviderError, "adapter down" }
        ) do
          assert_raises(SupplementalProviderError) do
            SupplementalClinicalResources.merged_observations_for_patient(REQUESTED_DFN)
          end
        end
      end

      test "unconfigured observations provider matches wire-only merge" do
        # Regression guard: the seam must be invisible when unused.
        with_supplemental_providers(observations: nil) do
          results = SupplementalClinicalResources.merged_observations_for_patient(REQUESTED_DFN)
          assert results.any?, "expected wire observations for patient 1"
          wire_ids = Observation.from_vital_hashes(
            Observation.for_patient(REQUESTED_DFN),
            patient_dfn: REQUESTED_DFN
          ).map(&:ien).sort
          assert_equal wire_ids, results.map(&:ien).sort
        end
      end

      test "observations provider receives the requested dfn" do
        # Catches using a stale/global patient key instead of the argument.
        received = []
        with_supplemental_providers(
          observations: ->(dfn) { received << dfn; [] }
        ) do
          SupplementalClinicalResources.merged_observations_for_patient(REQUESTED_DFN)
        end
        assert_equal [ REQUESTED_DFN ], received.map(&:to_s)
      end

      # -- AllergyIntolerance: patient compartment on supplemental slice --------

      test "merged_allergy_intolerances drops every supplemental row for another patient" do
        # Catches allergy supplemental merge without patient compartment enforcement.
        foreign = coded_allergy(ien: "foreign-allergy", patient_dfn: FOREIGN_DFN, allergen: "FOREIGN DRUG")

        with_supplemental_providers(
          allergy_intolerances: ->(_dfn) { [ foreign ] }
        ) do
          results = SupplementalClinicalResources.merged_allergy_intolerances_for_patient(REQUESTED_DFN)
          names = results.map { |r| allergy_label(r) }
          refute_includes names, "FOREIGN DRUG"
        end
      end

      test "merged_allergy_intolerances keeps owned supplemental rows and drops foreign ones in a mix" do
        # Catches partial allergy filtering when wire and supplemental rows are combined.
        owned = coded_allergy(
          ien: "owned-allergy", patient_dfn: REQUESTED_DFN,
          allergen: "Owned Supplemental Allergen", allergen_code: "12345", criticality: "high"
        )
        foreign = coded_allergy(ien: "foreign-allergy", patient_dfn: FOREIGN_DFN, allergen: "Foreign Allergen")

        with_supplemental_providers(
          allergy_intolerances: ->(_dfn) { [ owned, foreign ] }
        ) do
          results = SupplementalClinicalResources.merged_allergy_intolerances_for_patient(REQUESTED_DFN)
          names = results.map { |r| allergy_label(r) }
          assert_includes names, "Owned Supplemental Allergen"
          refute_includes names, "Foreign Allergen"
        end
      end

      test "merged_allergy_intolerances treats non-array provider output as no supplemental rows" do
        # Catches concat bugs when the allergy provider returns an unexpected type.
        baseline = SupplementalClinicalResources.merged_allergy_intolerances_for_patient(REQUESTED_DFN)

        with_supplemental_providers(allergy_intolerances: ->(_dfn) { { allergen: "oops" } }) do
          results = SupplementalClinicalResources.merged_allergy_intolerances_for_patient(REQUESTED_DFN)
          assert_equal baseline.map { |r| allergy_label(r) }.sort,
                       results.map { |r| allergy_label(r) }.sort
        end
      end

      test "merged_allergy_intolerances treats nil provider output as no supplemental rows" do
        # Catches nil-handling bugs that break wire-sourced allergy rows.
        baseline = SupplementalClinicalResources.merged_allergy_intolerances_for_patient(REQUESTED_DFN)

        with_supplemental_providers(allergy_intolerances: ->(_dfn) { nil }) do
          results = SupplementalClinicalResources.merged_allergy_intolerances_for_patient(REQUESTED_DFN)
          assert_equal baseline.map { |r| allergy_label(r) }.sort,
                       results.map { |r| allergy_label(r) }.sort
        end
      end

      test "configured allergy provider that raises does not fail silently as empty supplemental" do
        # Catches swallowing allergy adapter failures into an empty supplemental slice.
        with_supplemental_providers(
          allergy_intolerances: ->(_dfn) { raise SupplementalProviderError, "allergy adapter down" }
        ) do
          assert_raises(SupplementalProviderError) do
            SupplementalClinicalResources.merged_allergy_intolerances_for_patient(REQUESTED_DFN)
          end
        end
      end

      private

      def laboratory_observation(ien:, patient_dfn:, code:)
        Observation.new(
          ien: ien,
          patient_dfn: patient_dfn,
          code: code,
          code_system: "loinc",
          display: "Supplemental laboratory result",
          value_quantity: "6.1",
          unit: "%",
          category: "laboratory",
          status: "final",
          effective_datetime: Time.utc(2025, 6, 1, 12, 0, 0)
        )
      end

      def coded_allergy(ien:, patient_dfn:, allergen:, allergen_code: nil, criticality: nil)
        AllergyIntolerance.new(
          ien: ien,
          patient_dfn: patient_dfn,
          allergen: allergen,
          allergen_code: allergen_code,
          criticality: criticality,
          category: "medication",
          clinical_status: "active",
          reaction: "Hives",
          severity: "moderate"
        )
      end

      def allergy_label(record)
        record.is_a?(AllergyIntolerance) ? record.allergen : record[:allergen] || record["allergen"]
      end
    end
  end
end
