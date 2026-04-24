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

      def active? = clinical_status == "active"
      def resolved? = clinical_status == "resolved"
      def problem_list_item? = category == "problem-list-item"

      def to_fhir
        resource = {
          resourceType: "Condition",
          id: ien&.to_s,
          subject: patient_dfn ? { reference: "Patient/#{patient_dfn}" } : nil,
          clinicalStatus: clinical_status ? { coding: [ { code: clinical_status } ] } : nil,
          code: build_code,
          category: category ? [ { coding: [ { code: category } ] } ] : nil
        }.compact

        resource
      end

      private

      def build_code
        return nil unless code || display

        result = {}
        result[:coding] = [ { code: code } ] if code
        result[:text] = display if display
        result
      end
    end
  end
end
