# frozen_string_literal: true

module Lakeraven
  module EHR
    # PHI audit log — every authenticated FHIR read produces a row.
    # Immutable once written (ReadOnlyRecord on update).
    # No PHI in the row itself — only identifiers per ADR 0002.
    class AuditEvent < ApplicationRecord
      self.table_name = "lakeraven_ehr_audit_events"

      validates :event_type, presence: true
      validates :action, presence: true
      validates :outcome, presence: true
      validates :entity_type, presence: true

      scope :recent, -> { order(created_at: :desc) }

      def readonly?
        persisted?
      end
    end
  end
end
