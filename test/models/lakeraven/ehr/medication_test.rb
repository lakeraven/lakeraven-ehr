# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class MedicationTest < ActiveSupport::TestCase
      test "valid with id, display, and default status" do
        med = Medication.new(fhir_id: "med-861007", display: "Metformin hydrochloride 500 MG Oral Tablet")
        assert med.valid?
        assert_equal "active", med.status
        assert med.active?
      end

      test "invalid without fhir_id" do
        refute Medication.new(display: "Metformin").valid?
      end

      test "validates status inclusion" do
        refute Medication.new(fhir_id: "m", display: "d", status: "bogus").valid?
      end

      test "to_fhir emits an RxNorm-coded Medication" do
        med = Medication.new(
          fhir_id: "med-861007", code: "861007",
          display: "Metformin hydrochloride 500 MG Oral Tablet"
        )
        fhir = med.to_fhir
        assert_equal "Medication", fhir[:resourceType]
        assert_equal "med-861007", fhir[:id]
        assert_equal "active", fhir[:status]
        coding = fhir.dig(:code, :coding, 0)
        assert_equal "http://www.nlm.nih.gov/research/umls/rxnorm", coding[:system]
        assert_equal "861007", coding[:code]
        assert_equal "Metformin hydrochloride 500 MG Oral Tablet", coding[:display]
        assert_equal "Metformin hydrochloride 500 MG Oral Tablet", fhir.dig(:code, :text)
      end

      test "to_fhir omits coding when no code, keeps text" do
        fhir = Medication.new(fhir_id: "med-x", display: "Local drug name").to_fhir
        refute fhir[:code].key?(:coding)
        assert_equal "Local drug name", fhir.dig(:code, :text)
      end

      test "to_fhir includes form text when present" do
        fhir = Medication.new(fhir_id: "med-x", display: "D", form: "Oral tablet").to_fhir
        assert_equal "Oral tablet", fhir.dig(:form, :text)
      end
    end

    class MedicationStoreTest < ActiveSupport::TestCase
      teardown { MedicationStore.reset_instance! }

      test "find returns the seeded medication by id" do
        MedicationStore.instance.add(Medication.new(fhir_id: "med-1", display: "D"))
        assert_equal "D", MedicationStore.instance.find("med-1").display
        assert_nil MedicationStore.instance.find("med-2")
      end

      test "reset_instance! clears the store" do
        MedicationStore.instance.add(Medication.new(fhir_id: "med-1", display: "D"))
        MedicationStore.reset_instance!
        assert_equal 0, MedicationStore.instance.count
      end
    end
  end
end
