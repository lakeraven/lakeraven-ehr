# frozen_string_literal: true

module Lakeraven
  module EHR
    class Procedure
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :ien, :string
      attribute :patient_dfn, :string
      attribute :code, :string
      attribute :display, :string
      attribute :status, :string
      attribute :performed_datetime, :datetime
      attribute :performer_name, :string
      attribute :location_name, :string

      def self.for_patient(dfn)
        ProcedureGateway.for_patient(dfn)
      end

      def self.from_fhir(hash)
        h = hash.transform_keys(&:to_s)
        new(
          ien: h["id"],
          patient_dfn: h.dig("subject", "reference")&.delete_prefix("Patient/"),
          code: h.dig("code", "coding", 0, "code"),
          display: h.dig("code", "text"),
          status: h["status"],
          performed_datetime: h["performedDateTime"],
          performer_name: h.dig("performer", 0, "actor", "display"),
          location_name: h.dig("location", "display")
        )
      end

      def completed? = status == "completed"

      def to_fhir
        {
          resourceType: "Procedure",
          id: ien&.to_s,
          status: status,
          subject: patient_dfn ? { reference: "Patient/#{patient_dfn}" } : nil,
          code: build_code
        }.compact
      end

      private

      def build_code
        return nil unless code || display

        result = {}
        result[:coding] = [{ code: code }] if code
        result[:text] = display if display
        result
      end
    end
  end
end
