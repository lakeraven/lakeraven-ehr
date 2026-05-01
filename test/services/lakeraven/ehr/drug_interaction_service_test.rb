# frozen_string_literal: true

require "test_helper"
require "ostruct"

module Lakeraven
  module EHR
    class DrugInteractionServiceTest < ActiveSupport::TestCase
      # =============================================================================
      # INTERACTION ALERT VALUE OBJECT
      # =============================================================================

      test "InteractionAlert stores severity, drugs, and description" do
        alert = InteractionAlert.new(
          severity: :high, drug_a: "warfarin", drug_b: "aspirin",
          description: "Increased bleeding risk", source: "FDA"
        )

        assert_equal :high, alert.severity
        assert_equal "warfarin", alert.drug_a
        assert_equal "aspirin", alert.drug_b
        assert_equal "Increased bleeding risk", alert.description
        assert_equal "FDA", alert.source
      end

      test "InteractionAlert#severe? returns true for high severity" do
        alert = InteractionAlert.new(severity: :high, drug_a: "a", drug_b: "b", description: "test")
        assert alert.severe?
      end

      test "InteractionAlert#severe? returns false for moderate severity" do
        alert = InteractionAlert.new(severity: :moderate, drug_a: "a", drug_b: "b", description: "test")
        refute alert.severe?
      end

      test "InteractionAlert#severe? returns false for low severity" do
        alert = InteractionAlert.new(severity: :low, drug_a: "a", drug_b: "b", description: "test")
        refute alert.severe?
      end

      test "InteractionAlert defaults interaction_type to drug_drug" do
        alert = InteractionAlert.new(severity: :moderate, drug_a: "a", drug_b: "b", description: "test")
        assert_equal :drug_drug, alert.interaction_type
      end

      test "InteractionAlert supports drug-allergy type" do
        alert = InteractionAlert.new(
          severity: :high, drug_a: "amoxicillin", drug_b: "penicillin allergy",
          description: "Cross-reactivity risk", interaction_type: :drug_allergy
        )
        assert_equal :drug_allergy, alert.interaction_type
      end

      # =============================================================================
      # DRUG INTERACTION RESULT VALUE OBJECT
      # =============================================================================

      test "DrugInteractionResult#safe? returns true when no interactions" do
        result = DrugInteractionResult.new(interactions: [])
        assert result.safe?
      end

      test "DrugInteractionResult#safe? returns false when interactions exist" do
        alert = InteractionAlert.new(severity: :moderate, drug_a: "a", drug_b: "b", description: "test")
        result = DrugInteractionResult.new(interactions: [ alert ])
        refute result.safe?
      end

      test "DrugInteractionResult#blocking? returns true for high-severity" do
        alert = InteractionAlert.new(severity: :high, drug_a: "warfarin", drug_b: "aspirin", description: "Bleeding")
        result = DrugInteractionResult.new(interactions: [ alert ])
        assert result.blocking?
      end

      test "DrugInteractionResult#blocking? returns false for moderate-only" do
        alert = InteractionAlert.new(severity: :moderate, drug_a: "a", drug_b: "b", description: "test")
        result = DrugInteractionResult.new(interactions: [ alert ])
        refute result.blocking?
      end

      test "DrugInteractionResult#blocking? returns false when empty" do
        result = DrugInteractionResult.new(interactions: [])
        refute result.blocking?
      end

      test "DrugInteractionResult.success factory" do
        result = DrugInteractionResult.success
        assert result.safe?
        refute result.blocking?
        assert_empty result.interactions
      end

      test "DrugInteractionResult.failure factory" do
        result = DrugInteractionResult.failure(message: "Adapter unavailable")
        refute result.safe?
        assert_equal "Adapter unavailable", result.message
      end

      test "DrugInteractionResult#incomplete? when flagged" do
        result = DrugInteractionResult.new(interactions: [], incomplete: true, incomplete_reason: "Timeout")
        assert result.incomplete?
        refute result.safe?
      end

      test "DrugInteractionResult#to_fhir_detected_issues maps interactions" do
        alert = InteractionAlert.new(severity: :high, drug_a: "warfarin", drug_b: "aspirin", description: "Bleeding risk")
        result = DrugInteractionResult.new(interactions: [ alert ])
        issues = result.to_fhir_detected_issues

        assert_equal 1, issues.length
        assert_equal "DetectedIssue", issues.first[:resourceType]
        assert_equal "high", issues.first[:severity]
        assert_equal "Bleeding risk", issues.first[:detail][:text]
      end

      # =============================================================================
      # BASE ADAPTER INTERFACE
      # =============================================================================

      test "BaseAdapter#check_interactions raises NotImplementedError" do
        adapter = DrugInteraction::BaseAdapter.new
        assert_raises(NotImplementedError) { adapter.check_interactions([]) }
      end

      test "BaseAdapter#check_allergies raises NotImplementedError" do
        adapter = DrugInteraction::BaseAdapter.new
        assert_raises(NotImplementedError) { adapter.check_allergies("med", []) }
      end

      # =============================================================================
      # SERVICE ORCHESTRATION (adapter-backed)
      # =============================================================================

      test "check returns safe result when no interactions" do
        service = DrugInteractionService.new

        result = service.check(
          active_medications: [],
          proposed_medication: build_medication("acetaminophen", "161"),
          allergies: []
        )

        assert result.safe?
        assert_empty result.interactions
      end

      test "check detects drug-drug interaction via mock adapter" do
        service = DrugInteractionService.new

        result = service.check(
          active_medications: [ build_medication("warfarin", "11289") ],
          proposed_medication: build_medication("aspirin", "1191"),
          allergies: []
        )

        refute result.safe?
        assert result.blocking?
        assert result.interactions.any? { |a| a.drug_a.include?("warfarin") || a.drug_b.include?("warfarin") }
      end

      test "check detects drug-allergy interaction via mock adapter" do
        service = DrugInteractionService.new

        result = service.check(
          active_medications: [],
          proposed_medication: build_medication("amoxicillin", "723"),
          allergies: [ build_allergy("penicillin", "7984") ]
        )

        allergy_alerts = result.interactions.select { |a| a.interaction_type == :drug_allergy }
        assert allergy_alerts.any?
        assert_includes allergy_alerts.first.drug_b.downcase, "penicillin"
      end

      test "check returns DrugInteractionResult" do
        service = DrugInteractionService.new

        result = service.check(
          active_medications: [],
          proposed_medication: build_medication("tylenol", "161"),
          allergies: []
        )

        assert_kind_of DrugInteractionResult, result
      end

      test "check with multiple active meds checks all combinations" do
        service = DrugInteractionService.new

        result = service.check(
          active_medications: [
            build_medication("warfarin", "11289"),
            build_medication("metformin", "6809")
          ],
          proposed_medication: build_medication("aspirin", "1191"),
          allergies: []
        )

        assert_kind_of DrugInteractionResult, result
        assert result.interactions.any?
      end

      test "check handles adapter failure gracefully" do
        failing_adapter = ::OpenStruct.new
        failing_adapter.define_singleton_method(:check_interactions) { |_| raise "Connection refused" }
        failing_adapter.define_singleton_method(:check_allergies) { |_, _| [] }

        service = DrugInteractionService.new(adapter: failing_adapter)

        result = service.check(
          active_medications: [ build_medication("warfarin", "11289") ],
          proposed_medication: build_medication("aspirin", "1191"),
          allergies: []
        )

        assert result.incomplete?
        assert_includes result.incomplete_reason, "Connection refused"
      end

      test "check accepts custom adapter" do
        null_adapter = ::OpenStruct.new
        null_adapter.define_singleton_method(:check_interactions) { |_| [] }
        null_adapter.define_singleton_method(:check_allergies) { |_, _| [] }

        service = DrugInteractionService.new(adapter: null_adapter)

        result = service.check(
          active_medications: [ build_medication("warfarin", "11289") ],
          proposed_medication: build_medication("aspirin", "1191"),
          allergies: []
        )

        assert result.safe?
      end

      private

      def build_medication(display, code)
        ::OpenStruct.new(medication_display: display, medication_code: code)
      end

      def build_allergy(allergen, code)
        ::OpenStruct.new(allergen: allergen, allergen_code: code, category: "medication")
      end
    end
  end
end
