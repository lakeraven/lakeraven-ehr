# frozen_string_literal: true

module Lakeraven
  module EHR
    class Observation
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :ien, :string
      attribute :patient_dfn, :string
      attribute :code, :string
      attribute :display, :string
      attribute :value, :string
      attribute :value_quantity, :string
      attribute :unit, :string
      attribute :category, :string
      attribute :status, :string
      attribute :effective_datetime, :datetime

      def self.for_patient(dfn)
        ObservationGateway.for_patient(dfn)
      end

      def vital_sign? = category == "vital-signs"
      def laboratory? = category == "laboratory"

      def to_fhir
        {
          resourceType: "Observation",
          id: ien&.to_s,
          subject: patient_dfn ? { reference: "Patient/#{patient_dfn}" } : nil,
          status: respond_to?(:status) ? status : nil
        }.compact
      end
    end
  end
end
