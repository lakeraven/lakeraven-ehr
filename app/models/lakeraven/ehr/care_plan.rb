# frozen_string_literal: true

module Lakeraven
  module EHR
    class CarePlan
      include ActiveModel::Model
      include ActiveModel::Attributes
      include ActiveModel::Validations

      VALID_STATUSES = %w[draft active on-hold revoked completed entered-in-error unknown].freeze
      VALID_INTENTS = %w[proposal plan order option].freeze

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
      # entry is one planned activity's description text.
      attr_accessor :activities

      validates :patient_dfn, presence: true
      validates :status, inclusion: { in: VALID_STATUSES }
      validates :intent, inclusion: { in: VALID_INTENTS }

      # -- Gateway DI -----------------------------------------------------------

      class << self
        attr_writer :gateway

        def gateway
          @gateway || CarePlanGateway
        end
      end

      def self.for_patient(dfn)
        gateway.for_patient(dfn)
      end

      def self.resource_class
        "CarePlan"
      end

      # CarePlan.status to the REQUIRED CarePlan.activity.detail.status
      # binding (an activity on a revoked plan is cancelled, etc.).
      ACTIVITY_STATUS_MAP = {
        "active" => "in-progress",
        "completed" => "completed",
        "on-hold" => "on-hold",
        "revoked" => "cancelled",
        "draft" => "not-started"
      }.freeze

      # Build CarePlan instances from raw ORQQCP LIST hashes
      # ({ ien:, title:, status:, intent:, category:, start_date:, end_date:,
      #    author_duz:, author_name:, goal_iens:, activity:, description:,
      #    note: }). The wire's ACTIVITY piece is a single ";"-separated
      #    string; it splits into one activity entry per item.
      def self.from_rpc_hashes(hashes, patient_dfn:)
        Array(hashes).map do |h|
          new(
            ien: h[:ien]&.to_s,
            patient_dfn: patient_dfn.to_s,
            title: h[:title],
            description: h[:description],
            status: h[:status],
            intent: h[:intent],
            category: h[:category],
            period_start: h[:start_date],
            period_end: h[:end_date],
            author_name: h[:author_name],
            activities: h[:activity].to_s.split(";").map(&:strip).reject(&:empty?)
          )
        end
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
      # activity.detail.status carries a REQUIRED binding, derived from the
      # plan's own status ("unknown" when the plan status has no analogue).
      def build_activities
        return nil unless activities.is_a?(Array) && activities.any?

        detail_status = ACTIVITY_STATUS_MAP.fetch(status, "unknown")
        activities.map do |description|
          { detail: { status: detail_status, description: description } }
        end
      end
    end
  end
end
