# frozen_string_literal: true

require "test_helper"
require "ostruct"

module Lakeraven
  module EHR
    class DrugInteractionTest < ActiveSupport::TestCase
      # -- InteractionAlert ---------------------------------------------------

      test "InteractionAlert stores severity and drugs" do
        alert = InteractionAlert.new(
          severity: :high, drug_a: "warfarin", drug_b: "aspirin",
          description: "Bleeding risk"
        )
        assert_equal :high, alert.severity
        assert alert.severe?
      end

      test "moderate alert is not severe" do
        alert = InteractionAlert.new(
          severity: :moderate, drug_a: "lisinopril", drug_b: "potassium",
          description: "Hyperkalemia risk"
        )
        assert_not alert.severe?
      end

      test "drug-allergy interaction type" do
        alert = InteractionAlert.new(
          severity: :high, drug_a: "amoxicillin", drug_b: "penicillin allergy",
          description: "Allergy", interaction_type: :drug_allergy
        )
        assert_equal :drug_allergy, alert.interaction_type
      end

      # -- DrugInteractionResult -----------------------------------------------

      test "safe? when no interactions and complete" do
        result = DrugInteractionResult.new(interactions: [])
        assert result.safe?
        assert_not result.blocking?
      end

      test "not safe when interactions present" do
        alert = InteractionAlert.new(severity: :high, drug_a: "a", drug_b: "b", description: "x")
        result = DrugInteractionResult.new(interactions: [ alert ])
        assert_not result.safe?
        assert result.blocking?
      end

      test "not safe when incomplete (fail-closed)" do
        result = DrugInteractionResult.new(interactions: [], incomplete: true)
        assert_not result.safe?
      end

      test "failure result has message" do
        result = DrugInteractionResult.failure(message: "adapter error")
        assert_not result.safe?
        assert_equal "adapter error", result.message
      end

      test "decision_source tracks provenance" do
        result = DrugInteractionResult.new(interactions: [], decision_source: :rpms)
        assert_equal :rpms, result.decision_source
        assert_not result.degraded?
      end

      # -- DrugInteractionService ----------------------------------------------

      test "check detects warfarin-aspirin interaction" do
        result = DrugInteractionService.new.check(
          active_medications: [ med("warfarin", "11289") ],
          proposed_medication: med("aspirin", "1191"),
          allergies: []
        )
        assert_not result.safe?
        assert result.blocking?
        assert result.interactions.any? { |i| i.drug_a == "warfarin" && i.drug_b == "aspirin" }
      end

      test "check detects moderate ACE+potassium interaction" do
        result = DrugInteractionService.new.check(
          active_medications: [ med("lisinopril", "29046") ],
          proposed_medication: med("potassium chloride", "8591"),
          allergies: []
        )
        assert_not result.safe?
        assert_not result.blocking?
      end

      test "check returns safe for non-interacting drugs" do
        result = DrugInteractionService.new.check(
          active_medications: [ med("acetaminophen", "161") ],
          proposed_medication: med("amoxicillin", "723"),
          allergies: []
        )
        assert result.safe?
      end

      test "check detects drug-allergy interaction" do
        result = DrugInteractionService.new.check(
          active_medications: [ med("acetaminophen", "161") ],
          proposed_medication: med("amoxicillin", "723"),
          allergies: [ allergy("penicillin", "7980", "medication") ]
        )
        assert_not result.safe?
        assert result.interactions.any? { |i| i.interaction_type == :drug_allergy }
      end

      test "check detects cross-reactivity (penicillin → cephalosporin)" do
        result = DrugInteractionService.new.check(
          active_medications: [],
          proposed_medication: med("cephalexin", "2231"),
          allergies: [ allergy("penicillin", "7980", "medication") ]
        )
        assert_not result.safe?
        assert result.interactions.any? { |i| i.description&.include?("cross-reactivity") || i.description&.include?("Cross-reactivity") }
      end

      test "check safe for no active medications" do
        result = DrugInteractionService.new.check(
          active_medications: [],
          proposed_medication: med("lisinopril", "29046"),
          allergies: []
        )
        assert result.safe?
      end

      test "check detects multiple interactions" do
        result = DrugInteractionService.new.check(
          active_medications: [ med("warfarin", "11289"), med("fluoxetine", "4493") ],
          proposed_medication: med("ibuprofen", "5640"),
          allergies: []
        )
        assert_operator result.interactions.size, :>=, 2
      end

      test "unknown drug handled gracefully" do
        result = DrugInteractionService.new.check(
          active_medications: [ med("warfarin", "11289") ],
          proposed_medication: med("unknowndrug", "999999"),
          allergies: []
        )
        assert result.safe?
      end

      test "result includes FHIR DetectedIssue resources" do
        result = DrugInteractionService.new.check(
          active_medications: [ med("warfarin", "11289") ],
          proposed_medication: med("aspirin", "1191"),
          allergies: []
        )
        issues = result.to_fhir_detected_issues
        assert issues.any?
        assert_equal "DetectedIssue", issues.first[:resourceType]
      end

      # -- InteractionAlert edge cases -----------------------------------------

      test "InteractionAlert defaults interaction_type to drug_drug" do
        alert = InteractionAlert.new(
          severity: :high, drug_a: "a", drug_b: "b", description: "x"
        )
        assert_equal :drug_drug, alert.interaction_type
      end

      test "low severity is not severe" do
        alert = InteractionAlert.new(
          severity: :low, drug_a: "a", drug_b: "b", description: "x"
        )
        assert_not alert.severe?
      end

      # -- DrugInteractionResult edge cases ------------------------------------

      test "blocking? false for moderate-only interactions" do
        alert = InteractionAlert.new(
          severity: :moderate, drug_a: "a", drug_b: "b", description: "x"
        )
        result = DrugInteractionResult.new(interactions: [ alert ])
        assert_not result.blocking?
      end

      test "blocking? false when no interactions" do
        result = DrugInteractionResult.new(interactions: [])
        assert_not result.blocking?
      end

      test "interactions array accessible" do
        alert = InteractionAlert.new(severity: :high, drug_a: "a", drug_b: "b", description: "x")
        result = DrugInteractionResult.new(interactions: [ alert ])
        assert_equal 1, result.interactions.length
        assert_equal "a", result.interactions.first.drug_a
      end

      test "incomplete? returns true when data fetch failed" do
        result = DrugInteractionResult.new(interactions: [], incomplete: true)
        assert result.incomplete?
      end

      test "incomplete? returns false for complete data" do
        result = DrugInteractionResult.new(interactions: [])
        assert_not result.incomplete?
      end

      # -- DrugInteractionResult incomplete_reason / degraded_reason -----------

      test "incomplete result carries reason" do
        result = DrugInteractionResult.new(
          interactions: [], incomplete: true,
          incomplete_reason: "medication list unavailable from RPMS"
        )
        assert result.incomplete?
        assert_includes result.incomplete_reason, "medication list unavailable"
      end

      test "success factory is not incomplete" do
        result = DrugInteractionResult.success
        assert_not result.incomplete?
        assert result.safe?
      end

      test "success factory accepts decision_source and degraded" do
        result = DrugInteractionResult.success(decision_source: :rpms)
        assert_equal :rpms, result.decision_source
        assert_not result.degraded?
      end

      test "failure factory accepts decision_source and degraded" do
        result = DrugInteractionResult.failure(
          message: "error",
          decision_source: :local,
          degraded: true,
          degraded_reason: "using local rules"
        )
        assert_equal :local, result.decision_source
        assert result.degraded?
        assert_equal "using local rules", result.degraded_reason
      end

      test "degraded result carries reason" do
        result = DrugInteractionResult.new(
          interactions: [], degraded: true,
          degraded_reason: "local rules"
        )
        assert result.degraded?
        assert_equal "local rules", result.degraded_reason
      end

      test "degraded? defaults to false" do
        result = DrugInteractionResult.new(interactions: [])
        assert_not result.degraded?
      end

      test "success factory returns empty interactions" do
        result = DrugInteractionResult.success
        assert_empty result.interactions
        assert result.safe?
        assert_not result.blocking?
      end

      # -- Service edge cases --------------------------------------------------

      test "service handles food allergies gracefully" do
        result = DrugInteractionService.new.check(
          active_medications: [],
          proposed_medication: med("amoxicillin", "723"),
          allergies: [ allergy("shellfish", "999", "food") ]
        )
        # Food allergy shouldn't trigger drug-allergy interaction
        assert result.safe?
      end

      test "service with single medication and no allergies is safe" do
        result = DrugInteractionService.new.check(
          active_medications: [],
          proposed_medication: med("acetaminophen", "161"),
          allergies: []
        )
        assert result.safe?
        assert_equal 0, result.interactions.length
      end

      test "DetectedIssue includes severity" do
        result = DrugInteractionService.new.check(
          active_medications: [ med("warfarin", "11289") ],
          proposed_medication: med("aspirin", "1191"),
          allergies: []
        )
        issue = result.to_fhir_detected_issues.first
        assert issue[:severity].present?
      end

      private

      def med(name, code)
        ::OpenStruct.new(medication_display: name, medication_code: code)
      end

      def allergy(name, code, category)
        ::OpenStruct.new(allergen: name, allergen_code: code, category: category)
      end
    end
  end
end
