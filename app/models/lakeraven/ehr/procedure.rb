# frozen_string_literal: true

module Lakeraven
  module EHR
    class Procedure
      include ActiveModel::Model
      include ActiveModel::Attributes

      VALID_STATUSES = %w[preparation in-progress not-done on-hold stopped completed entered-in-error unknown].freeze

      CODE_SYSTEM_URLS = {
        "cpt" => "http://www.ama-assn.org/go/cpt",
        "snomed" => "http://snomed.info/sct"
      }.freeze

      attribute :ien, :string
      attribute :patient_dfn, :string
      attribute :code, :string
      attribute :code_system, :string
      attribute :display, :string
      attribute :status, :string
      attribute :performed_datetime, :datetime
      attribute :performer_duz, :string
      attribute :performer_name, :string
      attribute :location_ien, :string
      attribute :location_name, :string

      validates :patient_dfn, presence: true
      validates :display, presence: true
      validates :status, inclusion: { in: VALID_STATUSES, allow_blank: true }

      # -- Gateway DI -----------------------------------------------------------

      class << self
        attr_writer :gateway

        def gateway
          @gateway || ProcedureGateway
        end
      end

      def self.for_patient(dfn)
        gateway.for_patient(dfn)
      end

      def self.resource_class
        "Procedure"
      end

      def self.from_fhir_attributes(fhir_resource)
        {
          code: fhir_resource.code&.coding&.first&.code,
          display: fhir_resource.code&.text || fhir_resource.code&.coding&.first&.display,
          status: fhir_resource.status
        }
      end

      def completed? = status == "completed"

      def persisted?
        ien.present?
      end

      def to_fhir
        {
          resourceType: "Procedure",
          id: ien&.to_s,
          status: status,
          subject: patient_dfn ? { reference: "Patient/#{patient_dfn}" } : nil,
          code: build_code,
          performedDateTime: performed_datetime&.iso8601,
          performer: build_performers,
          location: build_location
        }.compact
      end

      private

      def build_code
        return nil unless code || display

        result = {}
        if code
          system_url = CODE_SYSTEM_URLS[code_system]
          result[:coding] = [ { code: code, system: system_url }.compact ]
        end
        result[:text] = display if display
        result
      end

      def build_performers
        return nil if performer_duz.blank?

        [ {
          actor: {
            reference: "Practitioner/#{performer_duz}",
            display: performer_name
          }.compact
        } ]
      end

      def build_location
        return nil if location_ien.blank?

        {
          reference: "Location/#{location_ien}",
          display: location_name
        }.compact
      end
    end
  end
end
