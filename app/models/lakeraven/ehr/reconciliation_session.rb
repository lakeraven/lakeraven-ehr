# frozen_string_literal: true

module Lakeraven
  module EHR
    # ReconciliationSession -- Clinical reconciliation workflow
    #
    # ONC 170.315(b)(2) -- Clinical Information Reconciliation
    class ReconciliationSession < ApplicationRecord
      self.table_name = "lakeraven_ehr_reconciliation_sessions"

      STATUSES = %w[pending in_progress completed cancelled].freeze

      has_many :reconciliation_items, dependent: :destroy,
               class_name: "Lakeraven::EHR::ReconciliationItem",
               foreign_key: :reconciliation_session_id

      validates :patient_dfn, presence: true
      validates :clinician_duz, presence: true
      validates :status, inclusion: { in: STATUSES }

      scope :active, -> { where(status: %w[pending in_progress]) }
      scope :for_patient, ->(dfn) { where(patient_dfn: dfn) }
      scope :by_clinician, ->(duz) { where(clinician_duz: duz) }

      def progress
        items = reconciliation_items
        decided = items.decided.count
        total = items.count
        {
          total: total,
          decided: decided,
          pending: total - decided,
          by_type: items.group(:resource_type).count
        }
      end

      def complete!
        return false if reconciliation_items.pending.any?

        update!(status: "completed", completed_at: Time.current)
        true
      end
    end
  end
end
