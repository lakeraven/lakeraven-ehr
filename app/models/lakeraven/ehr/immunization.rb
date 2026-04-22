# frozen_string_literal: true

module Lakeraven
  module EHR
    class Immunization
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :ien, :string
      attribute :patient_dfn, :string
      attribute :vaccine_code, :string
      attribute :vaccine_display, :string
      attribute :status, :string
      attribute :lot_number, :string
      attribute :expiration_date, :date
      attribute :site, :string
      attribute :route, :string
      attribute :performer_name, :string
      attribute :occurrence_datetime, :datetime

      def self.for_patient(dfn)
        ImmunizationGateway.for_patient(dfn)
      end

      def completed? = status == "completed"

      def to_fhir
        {
          resourceType: "Immunization",
          id: ien&.to_s,
          subject: patient_dfn ? { reference: "Patient/#{patient_dfn}" } : nil,
          status: respond_to?(:status) ? status : nil
        }.compact
      end
    end
  end
end
