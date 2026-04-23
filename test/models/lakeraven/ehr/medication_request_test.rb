# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class MedicationRequestTest < ActiveSupport::TestCase
      test "has medication attributes" do
        mr = MedicationRequest.new(
          ien: "1", patient_dfn: "100",
          medication_code: "11289", medication_display: "warfarin",
          status: "active", dosage_instruction: "Take 5mg daily",
          dose_quantity: "5", route: "oral", frequency: "daily"
        )
        assert_equal "11289", mr.medication_code
        assert_equal "warfarin", mr.medication_display
        assert_equal "5", mr.dose_quantity
        assert_equal "oral", mr.route
        assert_equal "daily", mr.frequency
      end

      test "active? for active status" do
        assert MedicationRequest.new(status: "active").active?
      end

      test "active? false for stopped" do
        refute MedicationRequest.new(status: "stopped").active?
      end

      test "stores authored_on" do
        dt = DateTime.new(2024, 1, 15, 10, 0)
        mr = MedicationRequest.new(authored_on: dt)
        assert_equal dt, mr.authored_on
      end

      test "stores requester_name" do
        mr = MedicationRequest.new(requester_name: "Dr. Smith")
        assert_equal "Dr. Smith", mr.requester_name
      end

      test "for_patient returns array" do
        results = MedicationRequest.for_patient(1)
        assert_kind_of Array, results
      end

      test "to_fhir returns MedicationRequest resource" do
        mr = MedicationRequest.new(ien: "42", patient_dfn: "100", status: "active")
        fhir = mr.to_fhir
        assert_equal "MedicationRequest", fhir[:resourceType]
        assert_equal "42", fhir[:id]
        assert_equal "active", fhir[:status]
      end

      test "to_fhir includes patient reference" do
        mr = MedicationRequest.new(ien: "1", patient_dfn: "100")
        fhir = mr.to_fhir
        assert_equal "Patient/100", fhir.dig(:subject, :reference)
      end

      test "to_fhir includes medicationCodeableConcept" do
        mr = MedicationRequest.new(ien: "1", medication_code: "11289", medication_display: "warfarin")
        fhir = mr.to_fhir
        assert_equal "11289", fhir.dig(:medicationCodeableConcept, :coding, 0, :code)
        assert_equal "warfarin", fhir.dig(:medicationCodeableConcept, :text)
      end

      test "to_fhir includes dosageInstruction" do
        mr = MedicationRequest.new(ien: "1", dosage_instruction: "Take 5mg daily")
        fhir = mr.to_fhir
        assert_equal "Take 5mg daily", fhir[:dosageInstruction]&.first&.dig(:text)
      end
    end
  end
end
