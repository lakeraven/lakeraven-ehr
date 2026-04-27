# frozen_string_literal: true

module Lakeraven
  module EHR
    # AmendmentRequest -- Patient health record amendment workflow
    #
    # ONC 170.315(d)(4) -- Amendments
    # HIPAA 164.526 -- Right of Amendment
    class AmendmentRequest < ApplicationRecord
      self.table_name = "lakeraven_ehr_amendment_requests"

      VALID_STATUSES = %w[pending accepted denied].freeze

      validates :patient_dfn, presence: true
      validates :resource_type, presence: true
      validates :description, presence: true
      validates :reason, presence: true
      validates :requested_by, presence: true
      validates :status, inclusion: { in: VALID_STATUSES }
      validates :review_reason, presence: true, if: -> { denied? }

      scope :for_patient, ->(dfn) { where(patient_dfn: dfn) }
      scope :pending_review, -> { where(status: "pending") }
      scope :chronological, -> { order(created_at: :asc) }
      scope :reverse_chronological, -> { order(created_at: :desc) }

      def pending? = status == "pending"
      def accepted? = status == "accepted"
      def denied? = status == "denied"

      def accept!(reviewer_duz:, reason: nil)
        update!(status: "accepted", reviewed_by: reviewer_duz, review_reason: reason, reviewed_at: Time.current)
        record_review_audit("amendment.accepted", reviewer_duz)
      end

      def deny!(reviewer_duz:, reason:)
        update!(status: "denied", reviewed_by: reviewer_duz, review_reason: reason, reviewed_at: Time.current)
        record_review_audit("amendment.denied", reviewer_duz)
      end

      private

      def record_review_audit(subtype, reviewer_duz)
        AuditEvent.create!(
          event_type: "application",
          action: "U",
          outcome: "0",
          agent_who_type: "Practitioner",
          agent_who_identifier: reviewer_duz,
          entity_id: id.to_s,
          entity_type: "AmendmentRequest",
          entity_identifier: id.to_s,
          outcome_desc: "#{subtype} for patient #{patient_dfn}"
        )
      end
    end
  end
end
