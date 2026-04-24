# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class DiagnosticReportTest < ActiveSupport::TestCase
      test "has report attributes" do
        dr = DiagnosticReport.new(
          ien: "1", patient_dfn: "100", code: "58410-2",
          code_display: "Complete blood count", status: "final",
          conclusion: "All values within normal limits",
          performer_name: "Lab Tech"
        )
        assert_equal "58410-2", dr.code
        assert_equal "Complete blood count", dr.code_display
        assert_equal "All values within normal limits", dr.conclusion
      end

      test "defaults status to final" do
        assert_equal "final", DiagnosticReport.new.status
      end

      test "final? for final status" do
        assert DiagnosticReport.new(status: "final").final?
      end

      test "final? false for preliminary" do
        refute DiagnosticReport.new(status: "preliminary").final?
      end

      test "stores effective and issued datetimes" do
        dt = DateTime.new(2024, 3, 15, 10, 0)
        dr = DiagnosticReport.new(effective_datetime: dt, issued: dt + 1.hour)
        assert_equal dt, dr.effective_datetime
      end

      test "to_fhir returns DiagnosticReport resource" do
        dr = DiagnosticReport.new(ien: "42", patient_dfn: "100", status: "final")
        fhir = dr.to_fhir
        assert_equal "DiagnosticReport", fhir[:resourceType]
        assert_equal "42", fhir[:id]
        assert_equal "final", fhir[:status]
      end

      test "to_fhir includes subject" do
        dr = DiagnosticReport.new(ien: "1", patient_dfn: "100")
        fhir = dr.to_fhir
        assert_equal "Patient/100", fhir.dig(:subject, :reference)
      end

      test "to_fhir includes code" do
        dr = DiagnosticReport.new(ien: "1", code_display: "CBC")
        fhir = dr.to_fhir
        assert_equal "CBC", fhir.dig(:code, :text)
      end

      test "to_fhir includes conclusion" do
        dr = DiagnosticReport.new(ien: "1", conclusion: "Normal")
        fhir = dr.to_fhir
        assert_equal "Normal", fhir[:conclusion]
      end
    end
  end
end
