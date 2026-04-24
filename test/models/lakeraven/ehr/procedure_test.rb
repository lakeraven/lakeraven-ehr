# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ProcedureTest < ActiveSupport::TestCase
      test "has procedure attributes" do
        p = Procedure.new(
          ien: "1", patient_dfn: "100", code: "27447",
          display: "Total knee replacement", status: "completed",
          performer_name: "Dr. Smith", location_name: "OR-1"
        )
        assert_equal "27447", p.code
        assert_equal "Total knee replacement", p.display
        assert_equal "Dr. Smith", p.performer_name
        assert_equal "OR-1", p.location_name
      end

      test "completed? for completed status" do
        assert Procedure.new(status: "completed").completed?
      end

      test "completed? false for in-progress" do
        refute Procedure.new(status: "in-progress").completed?
      end

      test "stores performed_datetime" do
        dt = DateTime.new(2024, 3, 15, 8, 0)
        p = Procedure.new(performed_datetime: dt)
        assert_equal dt, p.performed_datetime
      end

      test "for_patient returns array" do
        results = Procedure.for_patient(1)
        assert_kind_of Array, results
      end

      test "to_fhir returns Procedure resource" do
        p = Procedure.new(ien: "42", patient_dfn: "100", status: "completed")
        fhir = p.to_fhir
        assert_equal "Procedure", fhir[:resourceType]
        assert_equal "42", fhir[:id]
        assert_equal "completed", fhir[:status]
      end

      test "to_fhir includes subject" do
        p = Procedure.new(ien: "1", patient_dfn: "100")
        fhir = p.to_fhir
        assert_equal "Patient/100", fhir.dig(:subject, :reference)
      end

      test "to_fhir includes code" do
        p = Procedure.new(ien: "1", code: "27447", display: "Total knee replacement")
        fhir = p.to_fhir
        assert_equal "27447", fhir.dig(:code, :coding, 0, :code)
        assert_equal "Total knee replacement", fhir.dig(:code, :text)
      end
    end
  end
end
