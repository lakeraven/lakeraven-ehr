# frozen_string_literal: true

module Lakeraven
  module EHR
    class Goal
      include ActiveModel::Model
      include ActiveModel::Attributes
      include ActiveModel::Validations

      VALID_LIFECYCLE_STATUSES = %w[proposed planned accepted active on-hold completed cancelled entered-in-error rejected].freeze

      attribute :ien, :string
      attribute :patient_dfn, :string
      attribute :description, :string
      attribute :lifecycle_status, :string, default: "active"
      attribute :achievement_status, :string
      attribute :category, :string
      attribute :priority, :string
      attribute :start_date, :date
      attribute :target_date, :date

      validates :patient_dfn, presence: true
      validates :description, presence: true
      validates :lifecycle_status, inclusion: { in: VALID_LIFECYCLE_STATUSES }

      def active? = lifecycle_status == "active"
      def achieved? = achievement_status == "achieved"
      def persisted? = ien.present?

      def to_fhir
        {
          resourceType: "Goal",
          id: ien,
          lifecycleStatus: lifecycle_status,
          achievementStatus: build_achievement_status,
          description: { text: description },
          subject: patient_dfn ? { reference: "Patient/#{patient_dfn}" } : nil,
          startDate: start_date&.iso8601,
          target: build_target
        }.compact
      end

      private

      def build_achievement_status
        return nil unless achievement_status

        { coding: [ { code: achievement_status, system: "http://terminology.hl7.org/CodeSystem/goal-achievement" } ] }
      end

      def build_target
        return nil unless target_date

        [ { dueDate: target_date.iso8601 } ]
      end
    end
  end
end
