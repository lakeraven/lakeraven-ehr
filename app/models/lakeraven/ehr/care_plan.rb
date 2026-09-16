# frozen_string_literal: true

module Lakeraven
  module EHR
    # CarePlan is FIXTURE-SERVED: records are seeded into CarePlanStore (by
    # a deployment that can source them, e.g. the synthetic sandbox) and
    # served through this serializer. There is NO live RPC read path — the
    # previously-cited ORQQCP LIST wire mapping was never verified against a
    # real RPMS contract and has been removed rather than presumed.
    class CarePlan
      include ActiveModel::Model
      include ActiveModel::Attributes
      include ActiveModel::Validations

      VALID_STATUSES = %w[draft active on-hold revoked completed entered-in-error unknown].freeze
      VALID_INTENTS = %w[proposal plan order option].freeze

      # CarePlan.activity.detail.status carries a REQUIRED binding (R4
      # care-plan-activity-status).
      VALID_ACTIVITY_STATUSES = %w[
        not-started scheduled in-progress on-hold completed cancelled
        stopped unknown entered-in-error
      ].freeze

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

      # Array attribute — not natively typed by ActiveModel, use plain
      # accessor (mirrors Encounter#participant_practitioner_iens). Each
      # entry is one planned activity: either a String (description only) or
      # a Hash with :description and an optional activity-level :status.
      attr_accessor :activities

      validates :patient_dfn, presence: true
      validates :status, inclusion: { in: VALID_STATUSES }
      validates :intent, inclusion: { in: VALID_INTENTS }

      def self.resource_class
        "CarePlan"
      end

      def active? = status == "active"
      def persisted? = ien.present?

      def to_fhir
        {
          resourceType: "CarePlan",
          id: ien,
          status: status,
          intent: intent,
          title: title,
          description: description,
          category: build_category,
          subject: patient_dfn ? { reference: "Patient/#{patient_dfn}" } : nil,
          period: build_period,
          author: build_author,
          activity: build_activities
        }.compact
      end

      private

      def build_category
        return nil unless category

        [ { coding: [ { code: category, system: "http://hl7.org/fhir/us/core/CodeSystem/careplan-category" } ] } ]
      end

      def build_period
        return nil unless period_start || period_end

        p = {}
        p[:start] = period_start.iso8601 if period_start
        p[:end] = period_end.iso8601 if period_end
        p
      end

      def build_author
        return nil unless author_name

        { display: author_name }
      end

      # FHIR forbids empty arrays — omit activity entirely when absent.
      # activity.detail.status (REQUIRED binding, 1..1) comes from the
      # ACTIVITY's own recorded status when one exists; an activity without
      # one is "unknown". Per-activity progress is never inferred from the
      # plan's status — a plan being active says nothing about whether any
      # single activity is under way.
      def build_activities
        return nil unless activities.is_a?(Array) && activities.any?

        activities.map do |activity|
          detail =
            if activity.is_a?(Hash)
              { status: activity_status(activity[:status]), description: activity[:description] }
            else
              { status: "unknown", description: activity.to_s }
            end
          { detail: detail.compact }
        end
      end

      def activity_status(value)
        normalized = value.to_s.strip.downcase
        VALID_ACTIVITY_STATUSES.include?(normalized) ? normalized : "unknown"
      end
    end
  end
end
