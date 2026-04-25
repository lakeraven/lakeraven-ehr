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

      # -- Validations (ported from rpms_redux) ----------------------------------

      test "validates patient_dfn presence" do
        dr = DiagnosticReport.new(code_display: "CBC")
        assert_not dr.valid?
        assert_includes dr.errors[:patient_dfn], "can't be blank"
      end

      test "validates code_display presence" do
        dr = DiagnosticReport.new(patient_dfn: "123")
        assert_not dr.valid?
        assert_includes dr.errors[:code_display], "can't be blank"
      end

      test "validates status inclusion" do
        dr = DiagnosticReport.new(patient_dfn: "1", code_display: "CBC", status: "invalid")
        assert_not dr.valid?
        assert_includes dr.errors[:status], "is not included in the list"
      end

      test "allows valid status values" do
        %w[registered partial preliminary final amended corrected appended cancelled entered-in-error].each do |s|
          dr = DiagnosticReport.new(patient_dfn: "1", code_display: "CBC", status: s)
          assert dr.valid?, "Expected #{s} to be valid"
        end
      end

      test "validates category inclusion" do
        dr = DiagnosticReport.new(patient_dfn: "1", code_display: "CBC", category: "INVALID")
        assert_not dr.valid?
        assert_includes dr.errors[:category], "is not included in the list"
      end

      test "allows valid category values" do
        %w[LAB RAD].each do |cat|
          dr = DiagnosticReport.new(patient_dfn: "1", code_display: "CBC", category: cat)
          assert dr.valid?, "Expected #{cat} to be valid"
        end
      end

      test "nil category is valid (optional field)" do
        dr = DiagnosticReport.new(patient_dfn: "1", code_display: "CBC")
        assert dr.valid?
      end

      # -- FHIR extras (ported from rpms_redux) ----------------------------------

      test "to_fhir includes performer when performer_duz present" do
        dr = DiagnosticReport.new(
          ien: "1", patient_dfn: "100", code_display: "CBC",
          performer_duz: "789", performer_name: "Dr. Smith"
        )
        fhir = dr.to_fhir
        assert_equal 1, fhir[:performer].length
        assert_equal "Practitioner/789", fhir[:performer].first[:reference]
        assert_equal "Dr. Smith", fhir[:performer].first[:display]
      end

      test "to_fhir includes result references" do
        dr = DiagnosticReport.new(
          ien: "1", patient_dfn: "100", code_display: "CBC",
          result_iens: "10,20,30"
        )
        fhir = dr.to_fhir
        assert_equal 3, fhir[:result].length
        assert_equal "Observation/10", fhir[:result].first[:reference]
        assert_equal "Observation/20", fhir[:result][1][:reference]
        assert_equal "Observation/30", fhir[:result].last[:reference]
      end

      test "to_fhir includes presented_form" do
        dr = DiagnosticReport.new(
          ien: "1", patient_dfn: "100", code_display: "X-Ray",
          presented_form: "Full report text here"
        )
        fhir = dr.to_fhir
        assert_equal 1, fhir[:presentedForm].length
        assert_equal "text/plain", fhir[:presentedForm].first[:contentType]
        assert_equal Base64.strict_encode64("Full report text here"), fhir[:presentedForm].first[:data]
      end

      test "to_fhir includes effective datetime" do
        time = Time.zone.parse("2026-01-15 10:30:00")
        dr = DiagnosticReport.new(ien: "1", patient_dfn: "100", code_display: "CBC", effective_datetime: time)
        fhir = dr.to_fhir
        assert_equal time.iso8601, fhir[:effectiveDateTime]
      end

      test "to_fhir includes category coding for LAB" do
        dr = DiagnosticReport.new(ien: "1", patient_dfn: "100", code_display: "CBC", category: "LAB")
        fhir = dr.to_fhir
        coding = fhir[:category].first[:coding].first
        assert_equal "LAB", coding[:code]
        assert_equal "Laboratory", coding[:display]
      end

      test "to_fhir includes category coding for RAD" do
        dr = DiagnosticReport.new(ien: "1", patient_dfn: "100", code_display: "X-Ray", category: "RAD")
        fhir = dr.to_fhir
        coding = fhir[:category].first[:coding].first
        assert_equal "RAD", coding[:code]
        assert_equal "Radiology", coding[:display]
      end

      test "to_fhir includes LOINC code system for LAB" do
        dr = DiagnosticReport.new(ien: "1", patient_dfn: "100", code: "58410-2", code_display: "CBC", category: "LAB")
        fhir = dr.to_fhir
        coding = fhir[:code][:coding].first
        assert_equal "58410-2", coding[:code]
        assert_equal "http://loinc.org", coding[:system]
      end

      test "to_fhir includes CPT code system for RAD" do
        dr = DiagnosticReport.new(ien: "1", patient_dfn: "100", code: "71020", code_display: "Chest X-Ray", category: "RAD")
        fhir = dr.to_fhir
        coding = fhir[:code][:coding].first
        assert_equal "71020", coding[:code]
        assert_equal "http://www.ama-assn.org/go/cpt", coding[:system]
      end

      test "persisted? true when ien present" do
        assert DiagnosticReport.new(ien: "1", patient_dfn: "1", code_display: "CBC").persisted?
      end

      test "persisted? false when ien blank" do
        refute DiagnosticReport.new(patient_dfn: "1", code_display: "CBC").persisted?
      end
    end
  end
end
