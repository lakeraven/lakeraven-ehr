# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class DetectedIssueTest < ActiveSupport::TestCase
      # =============================================================================
      # VALIDATIONS
      # =============================================================================

      test "valid with all required attributes" do
        issue = build_detected_issue
        assert issue.valid?
      end

      test "requires status" do
        issue = build_detected_issue(status: nil)
        assert_not issue.valid?
        assert_includes issue.errors[:status], "can't be blank"
      end

      test "requires code" do
        issue = build_detected_issue(code: nil)
        assert_not issue.valid?
        assert_includes issue.errors[:code], "can't be blank"
      end

      test "validates status inclusion" do
        issue = build_detected_issue(status: "invalid")
        assert_not issue.valid?
      end

      test "validates severity inclusion" do
        issue = build_detected_issue(severity: "invalid")
        assert_not issue.valid?
      end

      test "validates code inclusion" do
        issue = build_detected_issue(code: "invalid")
        assert_not issue.valid?
      end

      # =============================================================================
      # FHIR SERIALIZATION
      # =============================================================================

      test "to_fhir returns DetectedIssue resourceType" do
        issue = build_detected_issue
        fhir = issue.to_fhir

        assert_equal "DetectedIssue", fhir[:resourceType]
      end

      test "to_fhir includes status" do
        issue = build_detected_issue(status: "final")
        fhir = issue.to_fhir

        assert_equal "final", fhir[:status]
      end

      test "to_fhir includes severity" do
        issue = build_detected_issue(severity: "high")
        fhir = issue.to_fhir

        assert_equal "high", fhir[:severity]
      end

      test "to_fhir includes code as CodeableConcept" do
        issue = build_detected_issue(code: "drug-drug")
        fhir = issue.to_fhir

        assert_not_nil fhir[:code]
        coding = fhir[:code][:coding].first
        assert_equal "drug-drug", coding[:code]
      end

      test "to_fhir includes detail text" do
        issue = build_detected_issue(detail: "Warfarin + Aspirin: Increased bleeding risk")
        fhir = issue.to_fhir

        assert_equal "Warfarin + Aspirin: Increased bleeding risk", fhir[:detail]
      end

      test "to_fhir includes implicated items" do
        issue = build_detected_issue(
          implicated_items: [
            { display: "warfarin", reference: "MedicationRequest/1" },
            { display: "aspirin", reference: "MedicationRequest/2" }
          ]
        )
        fhir = issue.to_fhir

        assert_equal 2, fhir[:implicated].length
        assert_equal "warfarin", fhir[:implicated].first[:display]
      end

      test "to_fhir includes meta profile" do
        issue = build_detected_issue
        fhir = issue.to_fhir

        assert_not_nil fhir[:meta]
      end

      # =============================================================================
      # FACTORY FROM INTERACTION ALERT
      # =============================================================================

      test "from_interaction_alert creates DetectedIssue for drug-drug" do
        alert = InteractionAlert.new(
          severity: :high,
          drug_a: "warfarin",
          drug_b: "aspirin",
          description: "Increased bleeding risk",
          source: "FDA",
          interaction_type: :drug_drug
        )

        issue = DetectedIssue.from_interaction_alert(alert)

        assert_kind_of DetectedIssue, issue
        assert_equal "final", issue.status
        assert_equal "high", issue.severity
        assert_equal "drug-drug", issue.code
        assert_includes issue.detail, "warfarin"
        assert_includes issue.detail, "aspirin"
        assert_equal 2, issue.implicated_items.length
      end

      test "from_interaction_alert creates DetectedIssue for drug-allergy" do
        alert = InteractionAlert.new(
          severity: :high,
          drug_a: "amoxicillin",
          drug_b: "penicillin allergy",
          description: "Patient allergic to penicillin class",
          interaction_type: :drug_allergy
        )

        issue = DetectedIssue.from_interaction_alert(alert)

        assert_equal "drug-allergy", issue.code
      end

      test "from_interaction_alert maps severity symbols to strings" do
        [ :high, :moderate, :low ].each do |severity|
          alert = InteractionAlert.new(
            severity: severity,
            drug_a: "drug_a",
            drug_b: "drug_b",
            description: "test"
          )

          issue = DetectedIssue.from_interaction_alert(alert)
          assert_equal severity.to_s, issue.severity
        end
      end

      private

      def build_detected_issue(overrides = {})
        defaults = {
          status: "final",
          severity: "high",
          code: "drug-drug",
          detail: "Warfarin + Aspirin: Increased bleeding risk",
          implicated_items: [
            { display: "warfarin", reference: "MedicationRequest/1" },
            { display: "aspirin", reference: "MedicationRequest/2" }
          ]
        }

        DetectedIssue.new(defaults.merge(overrides))
      end
    end
  end
end
