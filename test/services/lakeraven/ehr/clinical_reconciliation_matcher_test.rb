# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ClinicalReconciliationMatcherTest < ActiveSupport::TestCase
      setup do
        @matcher = ClinicalReconciliationMatcher.new
      end

      # =============================================================================
      # ALLERGY MATCHING
      # =============================================================================

      test "matches allergies by RxNorm code — duplicate" do
        imported = [ { allergen: "Penicillin", allergen_code: "7980", clinical_status: "active" } ]
        existing = [
          AllergyIntolerance.new(ien: "1", allergen: "Penicillin V", allergen_code: "7980", clinical_status: "active")
        ]

        results = @matcher.match(imported, existing, resource_type: "AllergyIntolerance")

        assert_equal 1, results.length
        assert_equal "duplicate", results.first[:match_status]
        assert_equal "1", results.first[:internal_record][:ien]
      end

      test "matches allergies by normalized name when no code" do
        imported = [ { allergen: "penicillin", clinical_status: "active" } ]
        existing = [
          AllergyIntolerance.new(ien: "1", allergen: "Penicillin", clinical_status: "active")
        ]

        results = @matcher.match(imported, existing, resource_type: "AllergyIntolerance")

        assert_equal "duplicate", results.first[:match_status]
      end

      test "identifies new allergies with no match" do
        imported = [ { allergen: "Codeine", allergen_code: "2670", clinical_status: "active" } ]
        existing = [
          AllergyIntolerance.new(ien: "1", allergen: "Penicillin", allergen_code: "7980", clinical_status: "active")
        ]

        results = @matcher.match(imported, existing, resource_type: "AllergyIntolerance")

        assert_equal "new", results.first[:match_status]
        assert_nil results.first[:internal_record]
      end

      # =============================================================================
      # CONDITION MATCHING
      # =============================================================================

      test "matches conditions by ICD-10 code — duplicate" do
        imported = [ { code: "E11.9", display: "Type 2 diabetes", clinical_status: "active" } ]
        existing = [
          Condition.new(ien: "10", patient_dfn: "1", code: "E11.9", code_system: "icd10", display: "Diabetes Type 2", clinical_status: "active")
        ]

        results = @matcher.match(imported, existing, resource_type: "Condition")

        assert_equal "duplicate", results.first[:match_status]
      end

      test "matches conditions by normalized display text" do
        imported = [ { display: "essential hypertension", clinical_status: "active" } ]
        existing = [
          Condition.new(ien: "11", patient_dfn: "1", display: "Essential Hypertension", clinical_status: "active")
        ]

        results = @matcher.match(imported, existing, resource_type: "Condition")

        assert_equal "duplicate", results.first[:match_status]
      end

      test "identifies new conditions" do
        imported = [ { code: "J45.909", display: "Asthma, unspecified", clinical_status: "active" } ]
        existing = [
          Condition.new(ien: "10", patient_dfn: "1", code: "E11.9", display: "Diabetes", clinical_status: "active")
        ]

        results = @matcher.match(imported, existing, resource_type: "Condition")

        assert_equal "new", results.first[:match_status]
      end

      # =============================================================================
      # MEDICATION MATCHING
      # =============================================================================

      test "matches medications by RxNorm code — duplicate" do
        imported = [ { medication_code: "311364", medication_display: "Lisinopril 10mg", status: "active" } ]
        existing = [
          MedicationRequest.new(ien: "20", patient_dfn: "1", medication_code: "311364", medication_display: "Lisinopril", status: "active")
        ]

        results = @matcher.match(imported, existing, resource_type: "MedicationRequest")

        assert_equal "duplicate", results.first[:match_status]
      end

      test "matches medications by normalized drug name" do
        imported = [ { medication_display: "lisinopril 10 mg oral tablet", status: "active" } ]
        existing = [
          MedicationRequest.new(ien: "20", patient_dfn: "1", medication_display: "Lisinopril 10 MG Oral Tablet", status: "active")
        ]

        results = @matcher.match(imported, existing, resource_type: "MedicationRequest")

        assert_equal "duplicate", results.first[:match_status]
      end

      test "identifies new medications" do
        imported = [ { medication_code: "860975", medication_display: "Metformin 500mg", status: "active" } ]
        existing = [
          MedicationRequest.new(ien: "20", patient_dfn: "1", medication_code: "311364", medication_display: "Lisinopril", status: "active")
        ]

        results = @matcher.match(imported, existing, resource_type: "MedicationRequest")

        assert_equal "new", results.first[:match_status]
      end

      # =============================================================================
      # CONFLICT DETECTION
      # =============================================================================

      test "detects conflict when code matches but clinical status differs" do
        imported = [ { allergen: "Penicillin", allergen_code: "7980", clinical_status: "resolved" } ]
        existing = [
          AllergyIntolerance.new(ien: "1", allergen: "Penicillin", allergen_code: "7980", clinical_status: "active")
        ]

        results = @matcher.match(imported, existing, resource_type: "AllergyIntolerance")

        assert_equal "conflict", results.first[:match_status]
      end

      test "detects conflict for conditions with different status" do
        imported = [ { code: "E11.9", display: "Diabetes", clinical_status: "resolved" } ]
        existing = [
          Condition.new(ien: "10", patient_dfn: "1", code: "E11.9", display: "Diabetes", clinical_status: "active")
        ]

        results = @matcher.match(imported, existing, resource_type: "Condition")

        assert_equal "conflict", results.first[:match_status]
      end

      # =============================================================================
      # EMPTY / EDGE CASES
      # =============================================================================

      test "returns empty array when no imported items" do
        results = @matcher.match([], [], resource_type: "AllergyIntolerance")
        assert_empty results
      end

      test "all items are new when no existing records" do
        imported = [
          { allergen: "Penicillin", allergen_code: "7980", clinical_status: "active" },
          { allergen: "Codeine", allergen_code: "2670", clinical_status: "active" }
        ]

        results = @matcher.match(imported, [], resource_type: "AllergyIntolerance")

        assert results.all? { |r| r[:match_status] == "new" }
      end
    end
  end
end
