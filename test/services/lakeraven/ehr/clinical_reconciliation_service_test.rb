# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ClinicalReconciliationServiceTest < ActiveSupport::TestCase
      # Stub CcdaParser (removed in #128, pending Nokogiri CI fix)
      class StubCcdaParser
        def parse(xml) = { conditions: [], allergies: [], medications: [] }
      end

      setup do
        @matcher = ClinicalReconciliationMatcher.new
        @ccda_parser = StubCcdaParser.new
        @service = ClinicalReconciliationService.new(matcher: @matcher, ccda_parser: @ccda_parser)
      end

      # =========================================================================
      # FHIR BUNDLE IMPORT
      # =========================================================================

      test "import_from_fhir_bundle succeeds with valid bundle" do
        bundle = {
          "resourceType" => "Bundle",
          "entry" => [
            { "resource" => {
              "resourceType" => "AllergyIntolerance",
              "subject" => { "reference" => "Patient/123" },
              "code" => { "text" => "Penicillin", "coding" => [ { "code" => "7980" } ] }
            } }
          ]
        }

        result = @service.import_from_fhir_bundle(
          patient_dfn: "123", clinician_duz: "301",
          json_string: bundle.to_json
        )

        assert result.success?
      end

      test "import_from_fhir_bundle rejects invalid JSON" do
        result = @service.import_from_fhir_bundle(
          patient_dfn: "123", clinician_duz: "301",
          json_string: "not-json"
        )

        refute result.success?
        assert result.errors.any? { |e| e.include?("Invalid JSON") }
      end

      test "import_from_fhir_bundle rejects non-Bundle resourceType" do
        json = { "resourceType" => "Patient" }.to_json

        result = @service.import_from_fhir_bundle(
          patient_dfn: "123", clinician_duz: "301",
          json_string: json
        )

        refute result.success?
        assert result.errors.any? { |e| e.include?("Bundle") }
      end

      test "import_from_fhir_bundle rejects resources for wrong patient" do
        bundle = {
          "resourceType" => "Bundle",
          "entry" => [
            { "resource" => {
              "resourceType" => "Condition",
              "subject" => { "reference" => "Patient/999" },
              "code" => { "coding" => [ { "code" => "E11.9" } ] }
            } }
          ]
        }

        result = @service.import_from_fhir_bundle(
          patient_dfn: "123", clinician_duz: "301",
          json_string: bundle.to_json
        )

        refute result.success?
        assert result.errors.any? { |e| e.include?("different patient") }
      end

      # =========================================================================
      # FHIR RESOURCE EXTRACTION
      # =========================================================================

      test "extracts allergies from FHIR bundle entries" do
        entries = [
          {
            "resourceType" => "AllergyIntolerance",
            "code" => { "text" => "Penicillin", "coding" => [ { "code" => "7980", "display" => "Penicillin" } ] },
            "clinicalStatus" => { "coding" => [ { "code" => "active" } ] }
          }
        ]

        imported = @service.send(:extract_from_fhir_entries, entries)

        assert_equal 1, imported[:allergies].length
        assert_equal "Penicillin", imported[:allergies].first[:allergen]
        assert_equal "7980", imported[:allergies].first[:allergen_code]
      end

      test "extracts conditions from FHIR bundle entries" do
        entries = [
          {
            "resourceType" => "Condition",
            "code" => { "text" => "Diabetes", "coding" => [ { "code" => "E11.9", "system" => "http://snomed.info/sct" } ] },
            "clinicalStatus" => { "coding" => [ { "code" => "active" } ] }
          }
        ]

        imported = @service.send(:extract_from_fhir_entries, entries)

        assert_equal 1, imported[:conditions].length
        assert_equal "snomed", imported[:conditions].first[:code_system]
      end

      test "extracts medications from FHIR bundle entries" do
        entries = [
          {
            "resourceType" => "MedicationRequest",
            "medicationCodeableConcept" => {
              "text" => "Lisinopril 10mg",
              "coding" => [ { "code" => "311364" } ]
            },
            "status" => "active"
          }
        ]

        imported = @service.send(:extract_from_fhir_entries, entries)

        assert_equal 1, imported[:medications].length
        assert_equal "311364", imported[:medications].first[:medication_code]
      end

      # =========================================================================
      # PATIENT REFERENCE MATCHING
      # =========================================================================

      test "patient_reference_matches returns true when reference matches" do
        resource = { "subject" => { "reference" => "Patient/123" } }
        assert @service.send(:patient_reference_matches?, resource, "123")
      end

      test "patient_reference_matches returns true when no reference present" do
        resource = { "resourceType" => "Observation" }
        assert @service.send(:patient_reference_matches?, resource, "123")
      end

      test "patient_reference_matches returns false for different patient" do
        resource = { "subject" => { "reference" => "Patient/999" } }
        refute @service.send(:patient_reference_matches?, resource, "123")
      end
    end
  end
end
