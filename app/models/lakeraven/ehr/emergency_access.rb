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

      # Breaking the glass lands in the SAME log a reviewer is already
      # reading. A break-glass trail that lives only in this table is one more
      # place to remember to look, and the one nobody looks at.
      #
      # `after_create` rather than `after_commit`, deliberately: the grant and
      # its audit row commit together or not at all. If the glass cannot be
      # broken audibly, it is not broken.
      after_create :record_emergency_access_audit!

      def readonly?
        persisted?
      end

      def active?
        expires_at > Time.current
      end

      def reviewed?
        reviewed_at.present?
      end

      private

      # The REASON CODE, never the justification. That is free text a
      # clinician typed under pressure — it belongs on this record and not in
      # a log built to hold no PHI (ADR 0002).
      def record_emergency_access_audit!
        AuditEvent.create!(
          event_type: "security",
          action: "E",
          outcome: "0",
          outcome_desc: "Emergency access (break-glass): #{reason}, expires #{expires_at&.iso8601}",
          entity_type: "Patient",
          entity_identifier: patient_dfn,
          agent_who_type: "Practitioner",
          agent_who_identifier: accessed_by,
          agent_name: accessed_by_name,
          agent_network_address: AuditContext.network_address,
          tenant_identifier: AuditContext.tenant_identifier,
          facility_identifier: AuditContext.facility_identifier
        )
      end
    end
  end
end
