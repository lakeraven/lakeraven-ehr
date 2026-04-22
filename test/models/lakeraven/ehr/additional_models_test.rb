# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class AdditionalModelsTest < ActiveSupport::TestCase
      # -- Device ----------------------------------------------------------------

      test "Device has UDI and manufacturer attributes" do
        d = Device.new(ien: "1", patient_dfn: "1", device_name: "Pacemaker",
                       manufacturer: "Medtronic", udi_carrier: "UDI123")
        assert_equal "Pacemaker", d.device_name
        assert_equal "Medtronic", d.manufacturer
        assert d.active?
      end

      test "Device to_fhir" do
        d = Device.new(ien: "1", patient_dfn: "1", device_name: "Pacemaker", status: "active")
        fhir = d.to_fhir
        assert_equal "Device", fhir[:resourceType]
        assert_equal "Patient/1", fhir.dig(:patient, :reference)
      end

      # -- DiagnosticReport ------------------------------------------------------

      test "DiagnosticReport has code and conclusion" do
        dr = DiagnosticReport.new(code_display: "CBC", conclusion: "Normal", status: "final")
        assert_equal "CBC", dr.code_display
        assert dr.final?
      end

      test "DiagnosticReport to_fhir" do
        dr = DiagnosticReport.new(ien: "1", patient_dfn: "1", code_display: "CBC", status: "final")
        fhir = dr.to_fhir
        assert_equal "DiagnosticReport", fhir[:resourceType]
      end

      # -- DocumentReference -----------------------------------------------------

      test "DocumentReference has content URL" do
        doc = DocumentReference.new(description: "Lab report", content_url: "/docs/123.pdf", content_type: "application/pdf")
        assert_equal "/docs/123.pdf", doc.content_url
        assert doc.current?
      end

      test "DocumentReference to_fhir" do
        doc = DocumentReference.new(subject_patient_dfn: "1", description: "Report", content_url: "/test.pdf")
        fhir = doc.to_fhir
        assert_equal "DocumentReference", fhir[:resourceType]
        assert_equal "/test.pdf", fhir[:content].first.dig(:attachment, :url)
      end

      # -- CarePlan --------------------------------------------------------------

      test "CarePlan has title and status" do
        cp = CarePlan.new(title: "Diabetes Management", status: "active", intent: "plan")
        assert_equal "Diabetes Management", cp.title
        assert cp.active?
      end

      test "CarePlan to_fhir" do
        cp = CarePlan.new(ien: "1", patient_dfn: "1", title: "Diabetes", status: "active", intent: "plan")
        fhir = cp.to_fhir
        assert_equal "CarePlan", fhir[:resourceType]
        assert_equal "plan", fhir[:intent]
      end

      # -- Goal ------------------------------------------------------------------

      test "Goal has description and lifecycle status" do
        g = Goal.new(description: "A1C below 7", lifecycle_status: "active")
        assert_equal "A1C below 7", g.description
        assert g.active?
      end

      test "Goal achieved?" do
        g = Goal.new(achievement_status: "achieved")
        assert g.achieved?
      end

      test "Goal to_fhir" do
        g = Goal.new(ien: "1", patient_dfn: "1", description: "A1C below 7", lifecycle_status: "active")
        fhir = g.to_fhir
        assert_equal "Goal", fhir[:resourceType]
        assert_equal "A1C below 7", fhir.dig(:description, :text)
      end

      # -- KernelUser ------------------------------------------------------------

      test "KernelUser has DUZ and name" do
        u = KernelUser.new(duz: 101, name: "MARTINEZ,SARAH", title: "MD")
        assert_equal 101, u.duz
        assert_equal "SARAH MARTINEZ", u.display_name
      end

      test "KernelUser to_param" do
        u = KernelUser.new(duz: 101)
        assert_equal "101", u.to_param
      end
    end
  end
end
