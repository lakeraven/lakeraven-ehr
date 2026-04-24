# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ConditionTest < ActiveSupport::TestCase
      # -- Attributes ----------------------------------------------------------

      test "has clinical attributes" do
        c = Condition.new(
          ien: "1", patient_dfn: "100", code: "E11.9",
          display: "Type 2 diabetes mellitus", clinical_status: "active",
          category: "problem-list-item", severity: "moderate"
        )
        assert_equal "E11.9", c.code
        assert_equal "Type 2 diabetes mellitus", c.display
        assert_equal "active", c.clinical_status
        assert_equal "problem-list-item", c.category
        assert_equal "moderate", c.severity
      end

      test "stores onset_datetime" do
        onset = DateTime.new(2020, 6, 15)
        c = Condition.new(onset_datetime: onset)
        assert_equal onset, c.onset_datetime
      end

      test "stores recorded_date" do
        c = Condition.new(recorded_date: Date.new(2024, 1, 15))
        assert_equal Date.new(2024, 1, 15), c.recorded_date
      end

      test "stores verification_status" do
        c = Condition.new(verification_status: "confirmed")
        assert_equal "confirmed", c.verification_status
      end

      # -- Predicates ----------------------------------------------------------

      test "active? for active status" do
        assert Condition.new(clinical_status: "active").active?
      end

      test "active? false for inactive" do
        refute Condition.new(clinical_status: "inactive").active?
      end

      test "active? false for resolved" do
        refute Condition.new(clinical_status: "resolved").active?
      end

      test "problem_list_item? for problem-list-item category" do
        assert Condition.new(category: "problem-list-item").problem_list_item?
      end

      test "problem_list_item? false for encounter-diagnosis" do
        refute Condition.new(category: "encounter-diagnosis").problem_list_item?
      end

      test "resolved? for resolved status" do
        assert Condition.new(clinical_status: "resolved").resolved?
      end

      test "resolved? false for active" do
        refute Condition.new(clinical_status: "active").resolved?
      end

      # -- Class methods -------------------------------------------------------

      test "for_patient returns array" do
        results = Condition.for_patient(1)
        assert_kind_of Array, results
      end

      # -- FHIR serialization --------------------------------------------------

      test "to_fhir returns Condition resource" do
        c = Condition.new(ien: "42", patient_dfn: "100")
        fhir = c.to_fhir
        assert_equal "Condition", fhir[:resourceType]
        assert_equal "42", fhir[:id]
        assert_equal "Patient/100", fhir.dig(:subject, :reference)
      end

      test "to_fhir includes clinicalStatus" do
        c = Condition.new(ien: "1", patient_dfn: "100", clinical_status: "active")
        fhir = c.to_fhir
        assert_equal "active", fhir.dig(:clinicalStatus, :coding, 0, :code)
      end

      test "to_fhir includes code" do
        c = Condition.new(ien: "1", patient_dfn: "100", code: "E11.9", display: "Diabetes")
        fhir = c.to_fhir
        assert_equal "E11.9", fhir.dig(:code, :coding, 0, :code)
        assert_equal "Diabetes", fhir.dig(:code, :text)
      end

      test "to_fhir includes category" do
        c = Condition.new(ien: "1", patient_dfn: "100", category: "problem-list-item")
        fhir = c.to_fhir
        assert fhir[:category]&.any?
      end

      test "to_fhir omits subject when no patient_dfn" do
        c = Condition.new(ien: "42")
        fhir = c.to_fhir
        assert_nil fhir[:subject]
      end
    end
  end
end
