# frozen_string_literal: true

module Lakeraven
  module EHR
    class CarePlan
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :ien, :string
      attribute :patient_dfn, :string
      attribute :title, :string
      attribute :description, :string
      attribute :status, :string, default: "active"
      attribute :intent, :string, default: "plan"
      attribute :category, :string
      attribute :period_start, :date
      attribute :period_end, :date
      attribute :author_name, :string

      def active? = status == "active"

      def to_fhir
        {
          resourceType: "CarePlan",
          id: ien,
          status: status,
          intent: intent,
          title: title,
          subject: patient_dfn ? { reference: "Patient/#{patient_dfn}" } : nil
        }.compact
      end
    end
  end
end
