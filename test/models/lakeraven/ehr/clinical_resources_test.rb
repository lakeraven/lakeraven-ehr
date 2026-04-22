# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ClinicalResourcesTest < ActiveSupport::TestCase
      # -- AllergyIntolerance ---------------------------------------------------

      test "AllergyIntolerance has attributes" do
        ai = AllergyIntolerance.new(allergen: "Penicillin", severity: "severe", category: "medication")
        assert_equal "Penicillin", ai.allergen
        assert_equal "severe", ai.severity
        assert ai.medication?
      end

      test "AllergyIntolerance defaults clinical_status to active" do
        assert AllergyIntolerance.new.active?
      end

      test "AllergyIntolerance to_fhir" do
        ai = AllergyIntolerance.new(patient_dfn: "1", allergen: "Penicillin", clinical_status: "active")
        fhir = ai.to_fhir
        assert_equal "AllergyIntolerance", fhir[:resourceType]
        assert_equal "Patient/1", fhir.dig(:patient, :reference)
      end

      # -- Condition -------------------------------------------------------------

      test "Condition has attributes" do
        c = Condition.new(code: "E11.9", display: "Type 2 diabetes", clinical_status: "active")
        assert_equal "E11.9", c.code
        assert c.active?
      end

      test "Condition to_fhir" do
        c = Condition.new(patient_dfn: "1", code: "E11.9", clinical_status: "active")
        fhir = c.to_fhir
        assert_equal "Condition", fhir[:resourceType]
        assert_equal "Patient/1", fhir.dig(:subject, :reference)
      end

      # -- MedicationRequest -----------------------------------------------------

      test "MedicationRequest has attributes" do
        mr = MedicationRequest.new(medication_display: "Metformin 500mg", status: "active", dosage_instruction: "Take twice daily")
        assert_equal "Metformin 500mg", mr.medication_display
        assert mr.active?
      end

      test "MedicationRequest to_fhir" do
        mr = MedicationRequest.new(patient_dfn: "1", medication_display: "Metformin", status: "active")
        fhir = mr.to_fhir
        assert_equal "MedicationRequest", fhir[:resourceType]
      end

      # -- Observation -----------------------------------------------------------

      test "Observation has attributes" do
        obs = Observation.new(code: "8480-6", display: "Systolic BP", value: "120", unit: "mmHg", category: "vital-signs")
        assert_equal "120", obs.value
        assert obs.vital_sign?
      end

      test "Observation laboratory?" do
        obs = Observation.new(category: "laboratory")
        assert obs.laboratory?
        refute obs.vital_sign?
      end

      test "Observation to_fhir" do
        obs = Observation.new(patient_dfn: "1", code: "8480-6", status: "final")
        fhir = obs.to_fhir
        assert_equal "Observation", fhir[:resourceType]
      end

      # -- Immunization ----------------------------------------------------------

      test "Immunization has attributes" do
        imm = Immunization.new(vaccine_code: "08", vaccine_display: "Hep B", status: "completed", lot_number: "LOT123")
        assert_equal "Hep B", imm.vaccine_display
        assert imm.completed?
      end

      test "Immunization to_fhir" do
        imm = Immunization.new(patient_dfn: "1", vaccine_code: "08", status: "completed")
        fhir = imm.to_fhir
        assert_equal "Immunization", fhir[:resourceType]
      end

      # -- Procedure -------------------------------------------------------------

      test "Procedure has attributes" do
        proc = Procedure.new(code: "99213", display: "Office visit", status: "completed")
        assert_equal "99213", proc.code
        assert proc.completed?
      end

      test "Procedure to_fhir" do
        proc = Procedure.new(patient_dfn: "1", code: "99213", status: "completed")
        fhir = proc.to_fhir
        assert_equal "Procedure", fhir[:resourceType]
      end

      # -- ServiceRequest --------------------------------------------------------

      test "ServiceRequest has attributes" do
        sr = ServiceRequest.new(ien: 12345, patient_dfn: 1, identifier: "2025-00123", referral_type: "C")
        assert_equal 12345, sr.ien
        assert_equal "2025-00123", sr.identifier
      end

      test "ServiceRequest to_fhir" do
        sr = ServiceRequest.new(ien: 1, patient_dfn: 1)
        fhir = sr.to_fhir
        assert_equal "ServiceRequest", fhir[:resourceType]
        assert_equal "Patient/1", fhir.dig(:subject, :reference)
      end
    end
  end
end
