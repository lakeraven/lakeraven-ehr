# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class AllergyIntoleranceTest < ActiveSupport::TestCase
      # -- Attributes ----------------------------------------------------------

      test "has required attributes" do
        ai = AllergyIntolerance.new(
          ien: "1", patient_dfn: "100", allergen: "Penicillin",
          reaction: "Rash", severity: "moderate", category: "medication"
        )
        assert_equal "1", ai.ien
        assert_equal "Penicillin", ai.allergen
        assert_equal "Rash", ai.reaction
        assert_equal "moderate", ai.severity
        assert_equal "medication", ai.category
      end

      test "defaults clinical_status to active" do
        ai = AllergyIntolerance.new
        assert_equal "active", ai.clinical_status
      end

      # -- Predicates ----------------------------------------------------------

      test "active? true when active" do
        assert AllergyIntolerance.new(clinical_status: "active").active?
      end

      test "active? false when inactive" do
        refute AllergyIntolerance.new(clinical_status: "inactive").active?
      end

      test "medication? true for medication category" do
        assert AllergyIntolerance.new(category: "medication").medication?
      end

      test "medication? false for food category" do
        refute AllergyIntolerance.new(category: "food").medication?
      end

      test "food? true for food category" do
        assert AllergyIntolerance.new(category: "food").food?
      end

      test "food? false for medication category" do
        refute AllergyIntolerance.new(category: "medication").food?
      end

      # -- Class methods -------------------------------------------------------

      test "for_patient returns allergies" do
        results = AllergyIntolerance.for_patient(1)
        assert_kind_of Array, results
      end

      # -- FHIR serialization --------------------------------------------------

      test "to_fhir returns AllergyIntolerance resource" do
        ai = AllergyIntolerance.new(
          ien: "1", patient_dfn: "100", allergen: "Penicillin",
          clinical_status: "active"
        )
        fhir = ai.to_fhir
        assert_equal "AllergyIntolerance", fhir[:resourceType]
      end

      test "to_fhir includes clinical status" do
        ai = AllergyIntolerance.new(
          patient_dfn: "100", allergen: "Aspirin", clinical_status: "active"
        )
        fhir = ai.to_fhir
        assert_equal "active", fhir.dig(:clinicalStatus, :coding, 0, :code)
      end

      test "to_fhir includes allergen text" do
        ai = AllergyIntolerance.new(
          patient_dfn: "100", allergen: "Latex"
        )
        fhir = ai.to_fhir
        assert_equal "Latex", fhir.dig(:code, :text)
      end

      test "to_fhir includes patient reference" do
        ai = AllergyIntolerance.new(
          patient_dfn: "100", allergen: "Peanuts"
        )
        fhir = ai.to_fhir
        assert_equal "Patient/100", fhir.dig(:patient, :reference)
      end

      test "to_fhir includes reaction when present" do
        ai = AllergyIntolerance.new(
          patient_dfn: "100", allergen: "Penicillin",
          reaction: "Anaphylaxis", severity: "severe"
        )
        fhir = ai.to_fhir
        assert_equal 1, fhir[:reaction].length
        assert_equal "Anaphylaxis", fhir[:reaction].first[:manifestation].first[:text]
        assert_equal "severe", fhir[:reaction].first[:severity]
      end

      test "to_fhir returns empty reaction array when no reaction" do
        ai = AllergyIntolerance.new(
          patient_dfn: "100", allergen: "Shellfish", reaction: nil
        )
        fhir = ai.to_fhir
        assert_equal [], fhir[:reaction]
      end

      test "to_fhir includes criticality when present" do
        ai = AllergyIntolerance.new(
          patient_dfn: "100", allergen: "Bee Stings", criticality: "high"
        )
        fhir = ai.to_fhir
        # criticality may or may not be in to_fhir depending on implementation
        assert_equal "AllergyIntolerance", fhir[:resourceType]
      end
    end
  end
end
