# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class EhiExportAllergyFetchTest < ActiveSupport::TestCase
      include SupplementalProviderConfigHelper

      PATIENT_DFN = "12345"

      setup do
        @_orig_patient = Patient.method(:find_by_dfn)
        @_orig_allergy = AllergyIntolerance.method(:for_patient)
        @_orig_med = MedicationRequest.method(:for_patient)

        Patient.define_singleton_method(:find_by_dfn) do |dfn|
          Patient.new(dfn: dfn.to_i, name: "Anderson,Alice", sex: "F", dob: 50.years.ago.to_date)
        end

        MedicationRequest.define_singleton_method(:for_patient) { |*_, **_| [] }
      end

      teardown do
        Patient.define_singleton_method(:find_by_dfn, @_orig_patient)
        AllergyIntolerance.define_singleton_method(:for_patient, @_orig_allergy)
        MedicationRequest.define_singleton_method(:for_patient, @_orig_med)
      end

      test "export calls AllergyIntolerance.for_patient exactly once when rows are models" do
        wire_rows = [
          allergy_model(ien: "wire-1", patient_dfn: PATIENT_DFN, allergen: "Penicillin"),
          allergy_model(ien: "wire-2", patient_dfn: PATIENT_DFN, allergen: "Shellfish")
        ]
        calls = install_allergy_stub(wire_rows)

        export_for_patient

        assert_equal 1, calls.length, "expected a single for_patient call, got #{calls.length}"
        assert_equal [ PATIENT_DFN ], calls.map(&:to_s)
      end

      test "export calls AllergyIntolerance.for_patient exactly once when rows are wire hashes" do
        wire_rows = [
          { patient_dfn: PATIENT_DFN, allergen: "Penicillin", ien: "hash-1", clinical_status: "active" }
        ]
        calls = install_allergy_stub(wire_rows)

        export_for_patient

        assert_equal 1, calls.length
      end

      test "export calls AllergyIntolerance.for_patient exactly once when wire returns an empty list" do
        calls = install_allergy_stub([])

        export_for_patient

        assert_equal 1, calls.length
      end

      test "export drops wire allergy models that name another patient" do
        wire_rows = [
          allergy_model(ien: "owned", patient_dfn: PATIENT_DFN, allergen: "Owned drug"),
          allergy_model(ien: "foreign", patient_dfn: "99999", allergen: "Foreign drug")
        ]
        install_allergy_stub(wire_rows)

        exported = exported_allergy_labels(export_for_patient)

        assert_includes exported, "Owned drug"
        refute_includes exported, "Foreign drug"
      end

      test "exported allergies match merged_allergy_intolerances_for_patient including supplemental rows" do
        wire_rows = [
          allergy_model(ien: "wire-owned", patient_dfn: PATIENT_DFN, allergen: "Wire Penicillin")
        ]
        supplemental = allergy_model(
          ien: "supplemental-owned",
          patient_dfn: PATIENT_DFN,
          allergen: "Supplemental Latex",
          allergen_code: "4242"
        )

        install_allergy_stub(wire_rows)

        with_supplemental_providers(
          allergy_intolerances: ->(_dfn) { [ supplemental ] }
        ) do
          expected = SupplementalClinicalResources.merged_allergy_intolerances_for_patient(PATIENT_DFN)
          result = export_for_patient
          exported = exported_allergy_resources(result)

          assert_equal expected.length, exported.length
          assert_equal expected.map { |r| r.ien }.sort, exported.map { |r| r["id"] }.sort
          assert_includes exported.map { |r| allergy_label_from_fhir(r) }, "Supplemental Latex"
        end
      end

      private

      def install_allergy_stub(return_value)
        calls = []
        AllergyIntolerance.define_singleton_method(:for_patient) do |dfn|
          calls << dfn
          return_value
        end
        calls
      end

      def export_for_patient
        EhiExportService.new(patient_dfn: PATIENT_DFN).export
      end

      def exported_allergy_resources(result)
        file = result[:files].find { |f| f[:name] == "allergy_intolerance.ndjson" }
        assert file.present?, "expected allergy_intolerance.ndjson in export"
        file[:content].each_line.filter_map do |line|
          next if line.strip.empty?

          JSON.parse(line)
        end
      end

      def exported_allergy_labels(result)
        exported_allergy_resources(result).map { |r| allergy_label_from_fhir(r) }
      end

      def allergy_label_from_fhir(fhir)
        fhir.dig("code", "text") ||
          fhir.dig("code", "coding", 0, "display") ||
          fhir["id"]
      end

      def allergy_model(ien:, patient_dfn:, allergen:, allergen_code: nil)
        AllergyIntolerance.new(
          ien: ien,
          patient_dfn: patient_dfn,
          allergen: allergen,
          allergen_code: allergen_code,
          clinical_status: "active",
          category: "medication",
          reaction: "Rash",
          severity: "mild"
        )
      end
    end
  end
end
