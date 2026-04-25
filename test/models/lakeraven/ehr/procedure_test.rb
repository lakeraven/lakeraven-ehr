# frozen_string_literal: true

require "test_helper"
require "ostruct"

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

      # -- validations -----------------------------------------------------------

      test "validates patient_dfn presence" do
        p = Procedure.new(display: "Office visit")
        refute p.valid?
        assert_includes p.errors[:patient_dfn], "can't be blank"
      end

      test "validates display presence" do
        p = Procedure.new(patient_dfn: "123")
        refute p.valid?
        assert_includes p.errors[:display], "can't be blank"
      end

      test "validates status values" do
        p = Procedure.new(patient_dfn: "123", display: "Office visit", status: "invalid")
        refute p.valid?
        assert_includes p.errors[:status], "is not included in the list"
      end

      test "allows valid status values" do
        %w[preparation in-progress not-done on-hold stopped completed entered-in-error unknown].each do |status|
          p = Procedure.new(patient_dfn: "123", display: "Office visit", status: status)
          assert p.valid?, "Expected #{status} to be valid"
        end
      end

      # -- resource_class --------------------------------------------------------

      test "resource_class returns Procedure" do
        assert_equal "Procedure", Procedure.resource_class
      end

      # -- persisted? ------------------------------------------------------------

      test "persisted? true when ien present" do
        p = Procedure.new(ien: "123", patient_dfn: "456", display: "Test")
        assert p.persisted?
      end

      test "persisted? false when ien blank" do
        p = Procedure.new(patient_dfn: "456", display: "Test")
        refute p.persisted?
      end

      # -- to_fhir code system URLs ----------------------------------------------

      test "to_fhir includes CPT code system URL" do
        p = Procedure.new(ien: "1", patient_dfn: "100", code: "99213", code_system: "cpt", display: "Office visit")
        fhir = p.to_fhir
        coding = fhir.dig(:code, :coding, 0)
        assert_equal "http://www.ama-assn.org/go/cpt", coding[:system]
      end

      test "to_fhir includes SNOMED code system URL" do
        p = Procedure.new(ien: "1", patient_dfn: "100", code: "71388002", code_system: "snomed", display: "Colonoscopy")
        fhir = p.to_fhir
        coding = fhir.dig(:code, :coding, 0)
        assert_equal "http://snomed.info/sct", coding[:system]
      end

      # -- to_fhir includes performed_datetime -----------------------------------

      test "to_fhir includes performed_datetime" do
        dt = DateTime.new(2026, 1, 15, 10, 30)
        p = Procedure.new(ien: "1", patient_dfn: "100", display: "Office visit", performed_datetime: dt)
        fhir = p.to_fhir
        assert_equal dt.iso8601, fhir[:performedDateTime]
      end

      # -- to_fhir includes performer -------------------------------------------

      test "to_fhir includes performer" do
        p = Procedure.new(
          ien: "1", patient_dfn: "100", display: "Office visit",
          performer_duz: "789", performer_name: "Dr. Smith"
        )
        fhir = p.to_fhir
        assert fhir[:performer]&.any?
        assert_equal "Practitioner/789", fhir[:performer].first.dig(:actor, :reference)
      end

      # -- to_fhir includes location --------------------------------------------

      test "to_fhir includes location" do
        p = Procedure.new(
          ien: "1", patient_dfn: "100", display: "Office visit",
          location_ien: "999", location_name: "Main Clinic"
        )
        fhir = p.to_fhir
        assert_equal "Location/999", fhir.dig(:location, :reference)
        assert_equal "Main Clinic", fhir.dig(:location, :display)
      end

      # -- from_fhir_attributes --------------------------------------------------

      test "from_fhir_attributes extracts attributes" do
        fhir_resource = OpenStruct.new(
          code: OpenStruct.new(
            coding: [OpenStruct.new(code: "99213", display: "Office visit")],
            text: "Office visit"
          ),
          status: "completed"
        )

        attrs = Procedure.from_fhir_attributes(fhir_resource)
        assert_equal "99213", attrs[:code]
        assert_equal "Office visit", attrs[:display]
        assert_equal "completed", attrs[:status]
      end
    end
  end
end
