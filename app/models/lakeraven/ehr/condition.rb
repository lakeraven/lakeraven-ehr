# frozen_string_literal: true

module Lakeraven
  module EHR
    class Condition
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :ien, :string
      attribute :patient_dfn, :string
      attribute :code, :string
      attribute :display, :string
      attribute :clinical_status, :string
      attribute :verification_status, :string
      attribute :category, :string
      attribute :severity, :string
      attribute :onset_datetime, :datetime
      attribute :recorded_date, :date

      def self.for_patient(dfn)
        ConditionGateway.for_patient(dfn)
      end

      def self.from_fhir(hash)
        h = hash.transform_keys(&:to_s)
        new(
          ien: h["id"],
          patient_dfn: h.dig("subject", "reference")&.delete_prefix("Patient/"),
          code: h.dig("code", "coding", 0, "code"),
          display: h.dig("code", "text"),
          clinical_status: h.dig("clinicalStatus", "coding", 0, "code"),
          verification_status: h.dig("verificationStatus", "coding", 0, "code"),
          category: h.dig("category", 0, "coding", 0, "code"),
          severity: h.dig("severity", "coding", 0, "code"),
          onset_datetime: h["onsetDateTime"],
          recorded_date: h["recordedDate"]
        )
      end

      def active? = clinical_status == "active"
      def resolved? = clinical_status == "resolved"
      def problem_list_item? = category == "problem-list-item"

      def to_fhir
        resource = {
          resourceType: "Condition",
          id: ien&.to_s,
          subject: patient_dfn ? { reference: "Patient/#{patient_dfn}" } : nil,
          clinicalStatus: clinical_status ? { coding: [{ code: clinical_status }] } : nil,
          code: build_code,
          category: category ? [{ coding: [{ code: category }] }] : nil
        }.compact

        resource
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
