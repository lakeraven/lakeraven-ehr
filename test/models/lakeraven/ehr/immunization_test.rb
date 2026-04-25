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

      # -- Validations ---------------------------------------------------------

      test "validates patient_dfn presence" do
        imm = Immunization.new(vaccine_display: "Flu shot")
        assert_not imm.valid?
        assert_includes imm.errors[:patient_dfn], "can't be blank"
      end

      test "validates vaccine_display presence" do
        imm = Immunization.new(patient_dfn: "123")
        assert_not imm.valid?
        assert_includes imm.errors[:vaccine_display], "can't be blank"
      end

      test "validates status values" do
        imm = Immunization.new(
          patient_dfn: "123", vaccine_display: "Flu shot", status: "invalid"
        )
        assert_not imm.valid?
        assert_includes imm.errors[:status], "is not included in the list"
      end

      test "allows valid status values" do
        %w[completed entered-in-error not-done].each do |status|
          imm = Immunization.new(
            patient_dfn: "123", vaccine_display: "Flu shot", status: status
          )
          assert imm.valid?, "Expected #{status} to be valid"
        end
      end

      # -- FHIR meta profile ---------------------------------------------------

      test "to_fhir includes US Core immunization profile in meta" do
        imm = Immunization.new(ien: "1", patient_dfn: "100", vaccine_display: "Flu")
        fhir = imm.to_fhir
        assert_includes fhir.dig(:meta, :profile),
          "http://hl7.org/fhir/us/core/StructureDefinition/us-core-immunization"
      end

      # -- FHIR CVX system ----------------------------------------------------

      test "to_fhir includes CVX system in vaccine coding" do
        imm = Immunization.new(ien: "1", vaccine_code: "141", vaccine_display: "Influenza")
        fhir = imm.to_fhir
        coding = fhir.dig(:vaccineCode, :coding, 0)
        assert_equal "http://hl7.org/fhir/sid/cvx", coding[:system]
      end

      # -- FHIR occurrence datetime -------------------------------------------

      test "to_fhir includes occurrenceDateTime" do
        time = DateTime.new(2026, 1, 15, 10, 30)
        imm = Immunization.new(ien: "1", patient_dfn: "100",
          vaccine_display: "Flu", occurrence_datetime: time)
        fhir = imm.to_fhir
        assert_equal time.iso8601, fhir[:occurrenceDateTime]
      end

      # -- FHIR site and route ------------------------------------------------

      test "to_fhir includes site and route" do
        imm = Immunization.new(ien: "1", patient_dfn: "100",
          vaccine_display: "Flu", site: "Left arm", route: "Intramuscular")
        fhir = imm.to_fhir
        assert_equal "Left arm", fhir.dig(:site, :text)
        assert_equal "Intramuscular", fhir.dig(:route, :text)
      end

      # -- FHIR performer -----------------------------------------------------

      test "has performer_duz attribute" do
        imm = Immunization.new(performer_duz: "789", performer_name: "Nurse Smith")
        assert_equal "789", imm.performer_duz
        assert_equal "Nurse Smith", imm.performer_name
      end

      test "to_fhir includes performer" do
        imm = Immunization.new(ien: "1", patient_dfn: "100",
          vaccine_display: "Flu", performer_duz: "789", performer_name: "Nurse Smith")
        fhir = imm.to_fhir
        assert_equal 1, fhir[:performer].length
        assert_equal "Practitioner/789", fhir[:performer].first.dig(:actor, :reference)
      end

      # -- VIS attributes ------------------------------------------------------

      test "has VIS attributes" do
        imm = Immunization.new(
          ien: "1", patient_dfn: "100", vaccine_display: "Flu",
          vis_edition_date: Date.new(2025, 8, 1),
          vis_presentation_date: Date.new(2026, 1, 15),
          vis_document_uri: "https://www.cdc.gov/vaccines/hcp/vis/vis-statements/flu.html"
        )
        assert_equal Date.new(2025, 8, 1), imm.vis_edition_date
        assert_equal Date.new(2026, 1, 15), imm.vis_presentation_date
        assert_equal "https://www.cdc.gov/vaccines/hcp/vis/vis-statements/flu.html", imm.vis_document_uri
      end

      # -- VFC eligibility attributes ------------------------------------------

      test "has VFC eligibility attributes" do
        imm = Immunization.new(
          ien: "1", patient_dfn: "100", vaccine_display: "Flu",
          vfc_eligibility_code: "V02", funding_source: "VFC"
        )
        assert_equal "V02", imm.vfc_eligibility_code
        assert_equal "VFC", imm.funding_source
      end

      # -- FHIR education (VIS) -----------------------------------------------

      test "to_fhir includes education element with VIS dates" do
        imm = Immunization.new(
          ien: "1", patient_dfn: "100", vaccine_display: "Flu",
          vis_edition_date: Date.new(2025, 8, 1),
          vis_presentation_date: Date.new(2026, 1, 15),
          vis_document_uri: "https://www.cdc.gov/vaccines/hcp/vis/vis-statements/flu.html"
        )
        fhir = imm.to_fhir
        assert_not_nil fhir[:education]
        edu = fhir[:education].first
        assert_equal "2025-08-01", edu[:publicationDate]
        assert_equal "2026-01-15", edu[:presentationDate]
        assert_equal "https://www.cdc.gov/vaccines/hcp/vis/vis-statements/flu.html", edu[:reference]
      end

      test "to_fhir omits education when no VIS data" do
        imm = Immunization.new(ien: "1", patient_dfn: "100", vaccine_display: "Flu")
        fhir = imm.to_fhir
        assert_nil fhir[:education]
      end

      # -- FHIR programEligibility (VFC) --------------------------------------

      test "to_fhir includes programEligibility with RPMS and HL7 codings" do
        imm = Immunization.new(
          ien: "1", patient_dfn: "100", vaccine_display: "Flu",
          vfc_eligibility_code: "V02"
        )
        fhir = imm.to_fhir
        assert_not_nil fhir[:programEligibility]
        codings = fhir[:programEligibility].first[:coding]
        assert_equal 2, codings.length

        rpms_coding = codings.find { |c| c[:system].include?("ihs.gov") }
        assert_equal "V02", rpms_coding[:code]

        hl7_coding = codings.find { |c| c[:system].include?("hl7.org") }
        assert_equal "eligible", hl7_coding[:code]
      end

      test "to_fhir maps V01 to ineligible in HL7 coding" do
        imm = Immunization.new(
          ien: "1", patient_dfn: "100", vaccine_display: "Flu",
          vfc_eligibility_code: "V01"
        )
        fhir = imm.to_fhir
        hl7_coding = fhir[:programEligibility].first[:coding].find { |c| c[:system].include?("hl7.org") }
        assert_equal "ineligible", hl7_coding[:code]
      end

      test "to_fhir omits programEligibility when no eligibility code" do
        imm = Immunization.new(ien: "1", patient_dfn: "100", vaccine_display: "Flu")
        fhir = imm.to_fhir
        assert_nil fhir[:programEligibility]
      end

      # -- FHIR fundingSource --------------------------------------------------

      test "to_fhir includes fundingSource with RPMS and HL7 codings" do
        imm = Immunization.new(
          ien: "1", patient_dfn: "100", vaccine_display: "Flu",
          funding_source: "VFC"
        )
        fhir = imm.to_fhir
        assert_not_nil fhir[:fundingSource]
        codings = fhir[:fundingSource][:coding]
        assert_equal 2, codings.length

        rpms_coding = codings.find { |c| c[:system].include?("ihs.gov") }
        assert_equal "VFC", rpms_coding[:code]

        hl7_coding = codings.find { |c| c[:system].include?("hl7.org") }
        assert_equal "public", hl7_coding[:code]
      end

      test "to_fhir maps private funding to private in HL7 coding" do
        imm = Immunization.new(
          ien: "1", patient_dfn: "100", vaccine_display: "Flu",
          funding_source: "private"
        )
        fhir = imm.to_fhir
        hl7_coding = fhir[:fundingSource][:coding].find { |c| c[:system].include?("hl7.org") }
        assert_equal "private", hl7_coding[:code]
      end

      test "to_fhir omits fundingSource when no funding data" do
        imm = Immunization.new(ien: "1", patient_dfn: "100", vaccine_display: "Flu")
        fhir = imm.to_fhir
        assert_nil fhir[:fundingSource]
      end

      # -- persisted? and resource_class ---------------------------------------

      test "persisted? returns true when ien present" do
        imm = Immunization.new(ien: "123", patient_dfn: "100", vaccine_display: "Test")
        assert imm.persisted?
      end

      test "persisted? returns false when ien blank" do
        imm = Immunization.new(patient_dfn: "100", vaccine_display: "Test")
        assert_not imm.persisted?
      end

      test "resource_class returns Immunization" do
        assert_equal "Immunization", Immunization.resource_class
      end
    end
  end
end
