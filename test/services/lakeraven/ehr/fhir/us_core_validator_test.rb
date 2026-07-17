# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    module FHIR
      class UsCoreValidatorTest < ActiveSupport::TestCase
        # =========================================================================
        # Patient
        # =========================================================================

        test "valid Patient passes validation" do
          patient = valid_patient
          result = UsCoreValidator.validate!(patient.to_fhir)

          assert_equal "Patient", result[:resourceType]
        end

        test "Patient missing race extension fails" do
          resource = valid_patient.to_fhir
          resource[:extension].delete_if { |e| e[:url].include?("us-core-race") }

          error = assert_raises(UsCoreValidationError) do
            UsCoreValidator.validate!(resource)
          end

          assert_includes error.errors.join, "race extension"
        end

        test "Patient missing ethnicity extension fails" do
          resource = valid_patient.to_fhir
          resource[:extension].delete_if { |e| e[:url].include?("us-core-ethnicity") }

          error = assert_raises(UsCoreValidationError) do
            UsCoreValidator.validate!(resource)
          end

          assert_includes error.errors.join, "ethnicity extension"
        end

        test "Patient missing birthsex extension fails" do
          resource = valid_patient.to_fhir
          resource[:extension].delete_if { |e| e[:url].include?("us-core-birthsex") }

          error = assert_raises(UsCoreValidationError) do
            UsCoreValidator.validate!(resource)
          end

          assert_includes error.errors.join, "birthsex extension"
        end

        test "Patient without name fails validation" do
          resource = valid_patient.to_fhir
          resource[:name] = []

          error = assert_raises(UsCoreValidationError) do
            UsCoreValidator.validate!(resource)
          end

          assert_includes error.errors.join, "name"
        end

        test "Patient validation messages never include PHI" do
          resource = valid_patient.to_fhir
          resource[:name] = []

          error = assert_raises(UsCoreValidationError) do
            UsCoreValidator.validate!(resource)
          end

          refute_includes error.message, valid_patient.name
          refute_includes error.message, valid_patient.dfn.to_s
        end

        # =========================================================================
        # Practitioner
        # =========================================================================

        test "valid Practitioner passes validation" do
          practitioner = valid_practitioner
          result = UsCoreValidator.validate!(practitioner.to_fhir)

          assert_equal "Practitioner", result[:resourceType]
        end

        test "Practitioner without identifier fails validation" do
          resource = valid_practitioner.to_fhir
          resource[:identifier] = []

          error = assert_raises(UsCoreValidationError) do
            UsCoreValidator.validate!(resource)
          end

          assert_includes error.errors.join, "identifier"
        end

        # =========================================================================
        # Observation
        # =========================================================================

        test "valid vital sign Observation passes validation" do
          obs = valid_heart_rate
          result = UsCoreValidator.validate!(obs.to_fhir)

          assert_equal "Observation", result[:resourceType]
        end

        test "valid blood pressure Observation passes validation" do
          obs = valid_blood_pressure
          result = UsCoreValidator.validate!(obs.to_fhir)

          assert_equal "Observation", result[:resourceType]
        end

        test "blood pressure missing systolic component fails" do
          resource = valid_blood_pressure.to_fhir
          resource[:component].delete_if { |c| c.dig(:code, :coding, 0, :code) == Observation::VITAL_SIGNS_CODES[:systolic] }

          error = assert_raises(UsCoreValidationError) do
            UsCoreValidator.validate!(resource)
          end

          assert_includes error.errors.join, "systolic component"
        end

        test "Observation without meta profile is skipped" do
          resource = {
            resourceType: "Observation",
            id: "1",
            status: "final",
            code: { coding: [ { code: "unknown" } ] }
          }

          errors = UsCoreValidator.validate(resource)
          assert_empty errors
        end

        # =========================================================================
        # Condition
        # =========================================================================

        test "valid Condition passes validation" do
          result = UsCoreValidator.validate!(valid_condition.to_fhir)

          assert_equal "Condition", result[:resourceType]
        end

        test "Condition without category fails validation" do
          resource = valid_condition.to_fhir
          resource.delete(:category)

          error = assert_raises(UsCoreValidationError) { UsCoreValidator.validate!(resource) }
          assert_includes error.errors.join, "category"
        end

        test "Condition without code fails validation" do
          resource = valid_condition.to_fhir
          resource.delete(:code)

          error = assert_raises(UsCoreValidationError) { UsCoreValidator.validate!(resource) }
          assert_includes error.errors.join, "code"
        end

        test "Condition without subject fails validation" do
          resource = valid_condition.to_fhir
          resource.delete(:subject)

          error = assert_raises(UsCoreValidationError) { UsCoreValidator.validate!(resource) }
          assert_includes error.errors.join, "subject"
        end

        test "Condition with text-only code passes validation" do
          resource = valid_condition.to_fhir
          resource[:code] = { text: "Essential hypertension" }

          assert_empty UsCoreValidator.validate(resource)
        end

        # =========================================================================
        # AllergyIntolerance
        # =========================================================================

        test "valid AllergyIntolerance passes validation" do
          result = UsCoreValidator.validate!(valid_allergy.to_fhir)

          assert_equal "AllergyIntolerance", result[:resourceType]
        end

        test "AllergyIntolerance without code fails validation" do
          resource = valid_allergy.to_fhir
          resource.delete(:code)

          error = assert_raises(UsCoreValidationError) { UsCoreValidator.validate!(resource) }
          assert_includes error.errors.join, "code"
        end

        test "AllergyIntolerance without patient fails validation" do
          resource = valid_allergy.to_fhir
          resource.delete(:patient)

          error = assert_raises(UsCoreValidationError) { UsCoreValidator.validate!(resource) }
          assert_includes error.errors.join, "patient"
        end

        private

        def valid_patient
          Patient.new(
            dfn: 1, name: "DOE,JOHN", sex: "M", dob: Date.new(1980, 1, 15),
            race: "AMERICAN INDIAN"
          )
        end

        def valid_practitioner
          Practitioner.new(ien: 101, name: "MARTINEZ,SARAH", npi: "1234567890")
        end

        def valid_heart_rate
          Observation.new(
            ien: "hr-1", patient_dfn: "1", category: "vital-signs",
            code: Observation::VITAL_SIGNS_CODES[:heart_rate],
            display: "Heart Rate", value: "72", value_quantity: "72",
            unit: "/min", status: "final",
            effective_datetime: DateTime.new(2025, 1, 15, 8, 0)
          )
        end

        def valid_blood_pressure
          Observation.new(
            ien: "bp-1", patient_dfn: "1", category: "vital-signs",
            code: Observation::VITAL_SIGNS_CODES[:blood_pressure],
            display: "Blood Pressure", value: "120/80", status: "final",
            effective_datetime: DateTime.new(2025, 1, 15, 8, 0)
          )
        end

        def valid_condition
          Condition.new(
            ien: "733", patient_dfn: "1", code: "I10", code_system: "icd10",
            display: "Essential hypertension", clinical_status: "active",
            category: "problem-list-item"
          )
        end

        def valid_allergy
          AllergyIntolerance.new(
            ien: "701", patient_dfn: "1", allergen: "PENICILLIN",
            reaction: "HIVES", severity: "moderate"
          )
        end
      end
    end
  end
end
