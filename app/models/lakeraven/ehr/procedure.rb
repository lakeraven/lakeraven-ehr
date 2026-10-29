# frozen_string_literal: true

module Lakeraven
  module EHR
    class Procedure
      include ActiveModel::Model
      include ActiveModel::Attributes

      VALID_STATUSES = %w[preparation in-progress not-done on-hold stopped completed entered-in-error unknown].freeze

      CODE_SYSTEM_URLS = {
        "cpt" => "http://www.ama-assn.org/go/cpt",
        "hcpcs" => "urn:oid:2.16.840.1.113883.6.285",
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

      # A row of RpmsRpc::Procedure.for_patient (a V CPT entry): a procedure
      # that was performed, so its status is completed. The row names the
      # provider and facility but carries no IEN for either.
      def self.from_rpms_row(row, patient_dfn:)
        new(
          ien: row[:ien].to_s.presence,
          patient_dfn: patient_dfn.to_s,
          code: row[:cpt_code].presence,
          code_system: hcpcs_level_ii?(row[:cpt_code]) ? "hcpcs" : "cpt",
          display: (row[:cpt_name] || row[:name]).presence,
          status: "completed",
          performed_datetime: row[:date],
          performer_name: row[:provider].presence,
          location_name: row[:facility].presence
        )
      end

      # V CPT holds HCPCS Level II codes too (a letter A-V and four digits,
      # e.g. A4206), which are not CPT.
      def self.hcpcs_level_ii?(code)
        code.to_s.match?(/\A[A-V]\d{4}\z/)
      end
      private_class_method :hcpcs_level_ii?

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
