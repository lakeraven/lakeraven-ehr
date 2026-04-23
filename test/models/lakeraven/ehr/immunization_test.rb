# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ImmunizationTest < ActiveSupport::TestCase
      # -- Attributes ----------------------------------------------------------

      test "has vaccine attributes" do
        imm = Immunization.new(
          ien: "1", patient_dfn: "100",
          vaccine_code: "08", vaccine_display: "Hep B, adolescent or pediatric",
          status: "completed", lot_number: "LOT123",
          site: "Left arm", route: "IM",
          performer_name: "Dr. Smith"
        )
        assert_equal "08", imm.vaccine_code
        assert_equal "Hep B, adolescent or pediatric", imm.vaccine_display
        assert_equal "LOT123", imm.lot_number
        assert_equal "Left arm", imm.site
        assert_equal "IM", imm.route
        assert_equal "Dr. Smith", imm.performer_name
      end

      test "stores occurrence_datetime" do
        dt = DateTime.new(2024, 3, 15, 10, 30)
        imm = Immunization.new(occurrence_datetime: dt)
        assert_equal dt, imm.occurrence_datetime
      end

      test "stores expiration_date" do
        imm = Immunization.new(expiration_date: Date.new(2025, 12, 31))
        assert_equal Date.new(2025, 12, 31), imm.expiration_date
      end

      test "stores dose_quantity and dose_unit" do
        imm = Immunization.new(dose_quantity: 0.5, dose_unit: "mL")
        assert_equal 0.5, imm.dose_quantity
        assert_equal "mL", imm.dose_unit
      end

      test "stores manufacturer" do
        imm = Immunization.new(manufacturer: "Merck")
        assert_equal "Merck", imm.manufacturer
      end

      # -- Predicates ----------------------------------------------------------

      test "completed? for completed status" do
        assert Immunization.new(status: "completed").completed?
      end

      test "completed? false for not-done" do
        refute Immunization.new(status: "not-done").completed?
      end

      test "not_done? for not-done status" do
        assert Immunization.new(status: "not-done").not_done?
      end

      test "entered_in_error? for entered-in-error status" do
        assert Immunization.new(status: "entered-in-error").entered_in_error?
      end

      # -- Class methods -------------------------------------------------------

      test "for_patient returns array" do
        results = Immunization.for_patient(1)
        assert_kind_of Array, results
      end

      # -- FHIR serialization --------------------------------------------------

      test "to_fhir returns Immunization resource" do
        imm = Immunization.new(ien: "42", patient_dfn: "100", status: "completed")
        fhir = imm.to_fhir
        assert_equal "Immunization", fhir[:resourceType]
        assert_equal "42", fhir[:id]
      end

      test "to_fhir includes status" do
        imm = Immunization.new(ien: "1", status: "completed")
        fhir = imm.to_fhir
        assert_equal "completed", fhir[:status]
      end

      test "to_fhir includes patient reference" do
        imm = Immunization.new(ien: "1", patient_dfn: "100")
        fhir = imm.to_fhir
        assert_equal "Patient/100", fhir.dig(:patient, :reference)
      end

      test "to_fhir includes vaccineCode" do
        imm = Immunization.new(ien: "1", vaccine_code: "08", vaccine_display: "Hep B")
        fhir = imm.to_fhir
        assert_equal "08", fhir.dig(:vaccineCode, :coding, 0, :code)
        assert_equal "Hep B", fhir.dig(:vaccineCode, :text)
      end

      test "to_fhir includes lotNumber" do
        imm = Immunization.new(ien: "1", lot_number: "LOT123")
        fhir = imm.to_fhir
        assert_equal "LOT123", fhir[:lotNumber]
      end

      test "to_fhir omits patient when no patient_dfn" do
        imm = Immunization.new(ien: "1")
        fhir = imm.to_fhir
        assert_nil fhir[:patient]
      end
    end
  end
end
