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

      def active? = status == "active"

      def to_fhir
        {
          resourceType: "MedicationRequest",
          id: ien&.to_s,
          subject: patient_dfn ? { reference: "Patient/#{patient_dfn}" } : nil,
          status: respond_to?(:status) ? status : nil
        }.compact
      end
    end
  end
end
