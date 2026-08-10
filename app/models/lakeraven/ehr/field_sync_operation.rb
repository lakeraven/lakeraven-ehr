# frozen_string_literal: true

module Lakeraven
  module EHR
    # FieldSyncOperation -- durable, idempotent record of one operation a field
    # iPad captured offline and submitted on reconnect (#418, #399, #410).
    #
    # The row is both the idempotency ledger (unique client_op_id makes a
    # replayed batch safe) and, when #outcome is "conflict", an entry in the
    # reconciliation queue a clinician must resolve. Reconciliation itself lives
    # in FieldSyncService; this model just holds the authoritative outcome.
    class FieldSyncOperation < ApplicationRecord
      self.table_name = "lakeraven_ehr_field_sync_operations"

      # Reconciliation dispatches on these; anything else is recorded with
      # outcome "rejected" for audit, so operation_type itself is validated for
      # presence only (a rejected op preserves the raw value the client sent).
      OPERATION_TYPES = %w[create update].freeze

      # Persisted outcomes. "duplicate" is deliberately NOT here: a replayed
      # client_op_id returns the ORIGINAL row unchanged (its real, persisted
      # outcome), tagged transiently via #replayed? so the response can report
      # it as a duplicate without rewriting history.
      OUTCOMES = %w[pending applied conflict rejected unsupported].freeze

      # Transient flag set by FieldSyncService when this row is returned for an
      # idempotent replay rather than a fresh reconciliation. Never persisted.
      attr_accessor :replayed

      validates :client_op_id, presence: true, uniqueness: true
      validates :operation_type, presence: true
      validates :target_type, presence: true
      validates :outcome, inclusion: { in: OUTCOMES }

      def replayed? = !!replayed

      scope :for_clinician, ->(duz) { where(clinician_duz: duz) }
      scope :for_site, ->(ien) { where(site_ien: ien) }
      scope :for_batch, ->(id) { where(batch_id: id) }
      scope :conflicts, -> { where(outcome: "conflict") }
      scope :unresolved_conflicts, -> { where(outcome: "conflict", resolved: false) }

      def conflict? = outcome == "conflict"
      def applied? = outcome == "applied"
      def duplicate? = outcome == "duplicate"
    end
  end
end
