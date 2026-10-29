# frozen_string_literal: true

module Lakeraven
  module EHR
    # Synthetic ActiveModel rows for CcdaGenerator specification (#233).
    module CcdaModelFixtures
      SYNTHETIC_DFN = 900_001

      def synthetic_patient(attrs = {})
        Patient.new({
          dfn: SYNTHETIC_DFN,
          name: "TEST,PATIENT ONE",
          dob: Date.parse("1975-06-15"),
          sex: "M",
          address_line1: "123 Main St",
          city: "Anchorage",
          state: "AK",
          zip_code: "99501"
        }.merge(attrs))
      end

      def synthetic_allergies
        [
          AllergyIntolerance.new(
            patient_dfn: SYNTHETIC_DFN.to_s,
            allergen_code: "7980",
            allergen: "Penicillin",
            clinical_status: "active"
          ),
          AllergyIntolerance.new(
            patient_dfn: SYNTHETIC_DFN.to_s,
            allergen_code: "36567",
            allergen: "Simvastatin",
            clinical_status: "active"
          )
        ]
      end

      def synthetic_conditions
        [
          Condition.new(
            patient_dfn: SYNTHETIC_DFN.to_s,
            code: "E11.9",
            code_system: "icd10",
            display: "Type 2 diabetes mellitus",
            clinical_status: "active"
          ),
          Condition.new(
            patient_dfn: SYNTHETIC_DFN.to_s,
            code: "I10",
            code_system: "icd10",
            display: "Essential hypertension",
            clinical_status: "active"
          )
        ]
      end

      def synthetic_medications
        [
          MedicationRequest.new(
            patient_dfn: SYNTHETIC_DFN.to_s,
            medication_code: "311364",
            medication_display: "Lisinopril 10 MG Oral Tablet",
            status: "active"
          ),
          MedicationRequest.new(
            patient_dfn: SYNTHETIC_DFN.to_s,
            medication_code: "860975",
            medication_display: "Metformin 500 MG Oral Tablet",
            status: "active"
          )
        ]
      end

      def synthetic_vitals
        [
          Observation.new(
            patient_dfn: SYNTHETIC_DFN.to_s,
            code: "8480-6",
            display: "Systolic BP",
            value: "120",
            unit: "mm[Hg]",
            category: "vital-signs",
            status: "final",
            effective_datetime: Time.zone.parse("2026-03-01 12:00:00")
          )
        ]
      end

      def synthetic_encounters
        [
          Encounter.new(
            patient_dfn: SYNTHETIC_DFN,
            status: "finished",
            class_code: "AMB",
            type_code: "99213",
            type_display: "Office visit",
            period_start: Time.zone.parse("2026-03-01 09:00:00"),
            practitioner_identifier: "Dr. Smith"
          )
        ]
      end

      def synthetic_author
        { name: "Dr. Smith", institution: "IHS Facility" }
      end
    end
  end
end
