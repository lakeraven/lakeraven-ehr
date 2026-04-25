# frozen_string_literal: true

module Lakeraven
  module EHR
    class SecurityIncident
      include ActiveModel::Model
      include ActiveModel::Attributes
      include ActiveModel::Validations

      class InvalidTransitionError < StandardError; end

      SEVERITIES = %w[low medium high critical].freeze
      STATUSES = %w[open investigating resolved].freeze
      INCIDENT_TYPES = %w[brute_force multiple_user_failure].freeze
      DEFAULT_THRESHOLD = 5

      VALID_TRANSITIONS = {
        "open" => %w[investigating resolved],
        "investigating" => %w[resolved],
        "resolved" => []
      }.freeze

      attribute :severity, :string
      attribute :incident_type, :string, default: "brute_force"
      attribute :status, :string, default: "open"
      attribute :description, :string
      attribute :source_ip, :string
      attribute :dedup_key, :string
      attribute :resolved_at, :datetime
      attribute :created_at, :datetime

      validates :severity, presence: true, inclusion: { in: SEVERITIES }
      validates :incident_type, presence: true, inclusion: { in: INCIDENT_TYPES }
      validates :status, presence: true, inclusion: { in: STATUSES }
      validates :description, presence: true
      validates :dedup_key, presence: true

      def open? = status == "open"
      def resolved? = status == "resolved"

      def investigate!
        transition_to!("investigating")
      end

      def resolve!
        transition_to!("resolved")
        self.resolved_at = Time.current
      end

      def self.configured_threshold
        raw = ENV["SECURITY_MONITOR_THRESHOLD"]
        value = Integer(raw, exception: false) if raw
        value && value >= 1 ? value : DEFAULT_THRESHOLD
      end

      def self.generate_dedup_key(incident_type, source_ip, time = Time.current)
        time_bucket = time.beginning_of_hour.to_i
        "#{incident_type}:#{source_ip}:#{time_bucket}"
      end

      private

      def transition_to!(new_status)
        allowed = VALID_TRANSITIONS[status] || []
        unless allowed.include?(new_status)
          raise InvalidTransitionError, "Cannot transition from '#{status}' to '#{new_status}'"
        end
        self.status = new_status
      end
    end
  end
end
