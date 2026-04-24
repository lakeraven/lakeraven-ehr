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
      attribute :dose_quantity, :float
      attribute :dose_unit, :string
      attribute :manufacturer, :string

      def self.for_patient(dfn)
        ImmunizationGateway.for_patient(dfn)
      end

      def completed? = status == "completed"
      def not_done? = status == "not-done"
      def entered_in_error? = status == "entered-in-error"

      def to_fhir
        {
          resourceType: "Immunization",
          id: ien&.to_s,
          status: status,
          patient: patient_dfn ? { reference: "Patient/#{patient_dfn}" } : nil,
          vaccineCode: build_vaccine_code,
          lotNumber: lot_number
        }.compact
      end

      private

      def build_vaccine_code
        return nil unless vaccine_code || vaccine_display

        result = {}
        result[:coding] = [ { code: vaccine_code } ] if vaccine_code
        result[:text] = vaccine_display if vaccine_display
        result
      end
    end
  end
end
