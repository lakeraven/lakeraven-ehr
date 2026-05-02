# frozen_string_literal: true

module Lakeraven
  module EHR
    # ReconciliationItem -- Individual item in a reconciliation session
    class ReconciliationItem < ApplicationRecord
      self.table_name = "lakeraven_ehr_reconciliation_items"

      RESOURCE_TYPES = %w[AllergyIntolerance Condition MedicationRequest].freeze
      MATCH_STATUSES = %w[new duplicate conflict].freeze
      DECISIONS = %w[pending accepted rejected].freeze

      belongs_to :reconciliation_session, class_name: "Lakeraven::EHR::ReconciliationSession"

      validates :resource_type, presence: true, inclusion: { in: RESOURCE_TYPES }
      validates :match_status, presence: true, inclusion: { in: MATCH_STATUSES }
      validates :decision, inclusion: { in: DECISIONS }

      scope :decided, -> { where(decision: %w[accepted rejected]) }
      scope :pending, -> { where(decision: "pending") }

      def accept!(duz)
        update!(decision: "accepted", decided_by_duz: duz, decided_at: Time.current)
      end

      def reject!(duz)
        update!(decision: "rejected", decided_by_duz: duz, decided_at: Time.current)
      end

      def new_item? = match_status == "new"
      def duplicate? = match_status == "duplicate"
      def conflict? = match_status == "conflict"
    end
  end
end
