# frozen_string_literal: true

module Lakeraven
  module EHR
    # One side effect bound for RPMS, written in the caller's transaction and
    # delivered at most once by RpmsOutbox.dispatch. pending -> delivering ->
    # delivered, or back to pending with backoff, or dead after the last
    # attempt. Only the error class is kept, never the message (no PHI).
    class RpmsOutboxEntry < ApplicationRecord
      self.table_name = "lakeraven_ehr_rpms_outbox_entries"

      PENDING = "pending"
      DELIVERING = "delivering"
      DELIVERED = "delivered"
      DEAD = "dead"
      STATUSES = [ PENDING, DELIVERING, DELIVERED, DEAD ].freeze

      validates :effect, :idempotency_key, :next_attempt_at, presence: true
      validates :status, inclusion: { in: STATUSES }
      validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    end
  end
end
