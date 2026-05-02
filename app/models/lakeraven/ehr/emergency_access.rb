# frozen_string_literal: true

module Lakeraven
  module EHR
    # EmergencyAccess -- Break-the-glass record
    #
    # ONC 170.315(d)(5) -- Emergency Access
    class EmergencyAccess < ApplicationRecord
      self.table_name = "lakeraven_ehr_emergency_accesses"

      VALID_REASONS = %w[
        medical_emergency psychiatric_emergency public_health_emergency
        disaster_response life_threatening
      ].freeze

      REVIEW_OUTCOMES = %w[appropriate inappropriate requires_followup].freeze

      DEFAULT_DURATION = 4.hours

      validates :patient_dfn, presence: true
      validates :accessed_by, presence: true
      validates :reason, presence: true, inclusion: { in: VALID_REASONS }
      validates :justification, presence: true
      validates :accessed_at, presence: true
      validates :expires_at, presence: true
      validates :review_outcome, inclusion: { in: REVIEW_OUTCOMES }, allow_nil: true

      scope :for_patient, ->(dfn) { where(patient_dfn: dfn) }
      scope :by_practitioner, ->(duz) { where(accessed_by: duz) }
      scope :pending_review, -> { where(reviewed_at: nil) }
      scope :reviewed, -> { where.not(reviewed_at: nil) }
      scope :active, -> { where("expires_at > ?", Time.current) }
      scope :recent, -> { order(accessed_at: :desc) }

      def readonly?
        persisted?
      end

      def active?
        expires_at > Time.current
      end

      def reviewed?
        reviewed_at.present?
      end
    end
  end
end
