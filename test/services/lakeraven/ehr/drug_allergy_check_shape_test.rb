# frozen_string_literal: true

require "test_helper"

# The drug-allergy safety check consumes MODEL instances: the interaction
# adapter calls `a.category` and `allergy.allergen`. The wire path
# (AllergyIntolerance.for_patient -> ORQQAL LIST) returns HASHES, which answer
# neither, so passing wire rows straight into the check raises NoMethodError
# the first time a patient actually has an allergy on file.
#
# Measured before this seam landed: `[{allergen: "Penicillin"}].select { |a|
# a.category }` raises "undefined method 'category' for an instance of Hash".
# A patient with no allergies returns [] and the check is skipped, so the
# defect is invisible until the data exists -- which is the worst time for a
# drug-allergy check to fail.
#
# These assert the shape contract at the boundary rather than the alert text,
# because the alert depends on configurable rules while the shape does not.
module Lakeraven
  module EHR
    class DrugAllergyCheckShapeTest < ActiveSupport::TestCase
      include SupplementalProviderConfigHelper

      DFN = "1"

      class WireShapedGateway
        def self.for_patient(_dfn)
          [ { ien: "", allergen: "Penicillin", severity: "severe", signs: "Hives" } ]
        end
      end

      def with_wire_gateway
        original = AllergyIntolerance.gateway
        AllergyIntolerance.gateway = WireShapedGateway
        yield
      ensure
        AllergyIntolerance.gateway = original
      end

      test "wire allergy rows reach the safety check as models, not hashes" do
        with_wire_gateway do
          allergies = SupplementalClinicalResources.merged_allergy_intolerances_for_patient(DFN)

          refute_empty allergies, "the gateway returned a row, so this must not be empty"
          allergies.each do |allergy|
            assert_respond_to allergy, :category,
              "the interaction adapter calls .category; a Hash here raises NoMethodError"
            assert_respond_to allergy, :allergen
          end
        end
      end

      test "a wire row with no IEN still gets a stable id" do
        with_wire_gateway do
          allergies = SupplementalClinicalResources.merged_allergy_intolerances_for_patient(DFN)
          ids = allergies.map { |a| a.ien.to_s }

          refute_empty ids
          refute_includes ids, "", "ORQQAL can return no IEN; a blank id breaks FHIR read-by-id"
          assert_equal ids, SupplementalClinicalResources
            .merged_allergy_intolerances_for_patient(DFN).map { |a| a.ien.to_s },
            "the derived id must be stable across reads"
        end
      end

      test "a supplemental coded allergy reaches the safety check too" do
        with_wire_gateway do
          coded = AllergyIntolerance.new(
            ien: "supp-1", patient_dfn: DFN, allergen: "Amoxicillin",
            allergen_code: "723", criticality: "high", category: "medication",
            clinical_status: "active", reaction: "Anaphylaxis", severity: "severe"
          )

          with_supplemental_providers(allergy_intolerances: ->(_dfn) { [ coded ] }) do
            allergies = SupplementalClinicalResources.merged_allergy_intolerances_for_patient(DFN)
            assert_includes allergies.map { |a| a.ien.to_s }, "supp-1",
              "a coded allergy supplied for safety checking must not be invisible to it"
          end
        end
      end

      # The wire slice is trusted to be patient-scoped by the RPC, but when a row
      # STATES its own patient that statement is what counts. Stamping the
      # requested DFN over it would launder a mis-scoped row -- a broker bug, a
      # stale cache, a bad LIST -- into this patient's compartment, and it would
      # arrive looking exactly like their own data.
      class ForeignRowGateway
        def self.for_patient(_dfn)
          [ { ien: "foreign-1", patient_dfn: "2", allergen: "FOREIGN DRUG",
              severity: "severe", signs: "Hives" } ]
        end
      end

      test "a wire row naming another patient is not laundered into this one" do
        original = AllergyIntolerance.gateway
        AllergyIntolerance.gateway = ForeignRowGateway
        allergies = SupplementalClinicalResources.merged_allergy_intolerances_for_patient(DFN)

        refute_includes allergies.map { |a| a.ien.to_s }, "foreign-1",
          "a wire row stating patient 2 must not be served as patient 1's"
        refute_includes allergies.map(&:allergen), "FOREIGN DRUG"
      ensure
        AllergyIntolerance.gateway = original
      end

      test "a supplemental row cannot shadow a wire row with the same id" do
        with_wire_gateway do
          wire_id = SupplementalClinicalResources
            .merged_allergy_intolerances_for_patient(DFN).first.ien.to_s
          impostor = AllergyIntolerance.new(
            ien: wire_id, patient_dfn: DFN, allergen: "NOT THE WIRE ROW",
            category: "medication", clinical_status: "active"
          )

          with_supplemental_providers(allergy_intolerances: ->(_dfn) { [ impostor ] }) do
            allergies = SupplementalClinicalResources.merged_allergy_intolerances_for_patient(DFN)
            assert_equal 1, allergies.count { |a| a.ien.to_s == wire_id }
            refute_includes allergies.map(&:allergen), "NOT THE WIRE ROW",
              "the wire row is the system of record and must win the id"
          end
        end
      end
    end
  end
end
