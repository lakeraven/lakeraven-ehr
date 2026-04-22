# frozen_string_literal: true

module Lakeraven
  module EHR
    class Goal
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :ien, :string
      attribute :patient_dfn, :string
      attribute :description, :string
      attribute :lifecycle_status, :string, default: "active"
      attribute :achievement_status, :string
      attribute :category, :string
      attribute :priority, :string
      attribute :start_date, :date
      attribute :target_date, :date

      def active? = lifecycle_status == "active"
      def achieved? = achievement_status == "achieved"

      def to_fhir
        {
          resourceType: "Goal",
          id: ien,
          lifecycleStatus: lifecycle_status,
          description: { text: description },
          subject: patient_dfn ? { reference: "Patient/#{patient_dfn}" } : nil
        }.compact
      end
    end
  end
end
