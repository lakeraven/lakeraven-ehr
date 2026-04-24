# frozen_string_literal: true

module Lakeraven
  module EHR
    class MedicationRequest
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :ien, :string
      attribute :patient_dfn, :string
      attribute :medication_code, :string
      attribute :medication_display, :string
      attribute :status, :string
      attribute :dosage_instruction, :string
      attribute :dose_quantity, :string
      attribute :route, :string
      attribute :frequency, :string
      attribute :authored_on, :datetime
      attribute :requester_name, :string

      def self.for_patient(dfn)
        MedicationRequestGateway.for_patient(dfn)
      end

      def self.from_fhir(hash)
        h = hash.transform_keys(&:to_s)
        new(
          ien: h["id"],
          patient_dfn: h.dig("subject", "reference")&.delete_prefix("Patient/"),
          medication_code: h.dig("medicationCodeableConcept", "coding", 0, "code"),
          medication_display: h.dig("medicationCodeableConcept", "text"),
          status: h["status"],
          dosage_instruction: h.dig("dosageInstruction", 0, "text"),
          authored_on: h["authoredOn"],
          requester_name: h.dig("requester", "display")
        )
      end

      def active? = status == "active"

      def to_fhir
        {
          resourceType: "MedicationRequest",
          id: ien&.to_s,
          status: status,
          subject: patient_dfn ? { reference: "Patient/#{patient_dfn}" } : nil,
          medicationCodeableConcept: build_medication_code,
          dosageInstruction: dosage_instruction ? [{ text: dosage_instruction }] : nil
        }.compact
      end

      private

      def build_medication_code
        return nil unless medication_code || medication_display

        result = {}
        result[:coding] = [{ code: medication_code }] if medication_code
        result[:text] = medication_display if medication_display
        result
      end
    end
  end
end
