# frozen_string_literal: true

require "securerandom"

# Per ADR 0004 every external identifier on FHIR resources must be
# an opaque *_identifier token, not the Rails primary key. AuditEvent
# was leaking `id` into the serialized Resource.id; this migration
# adds an aud_*-prefixed column and backfills existing rows.
class AddAuditEventIdentifierToLakeravenEHRAuditEvents < ActiveRecord::Migration[8.1]
  def up
    add_column :lakeraven_ehr_audit_events, :audit_event_identifier, :string

    # Backfill any existing rows (dev/test only — no production data).
    execute(<<~SQL.squish)
      UPDATE lakeraven_ehr_audit_events
      SET audit_event_identifier = 'aud_' || md5(id::text || now()::text)
      WHERE audit_event_identifier IS NULL
    SQL

    change_column_null :lakeraven_ehr_audit_events, :audit_event_identifier, false
    add_index :lakeraven_ehr_audit_events, :audit_event_identifier, unique: true
  end

  def down
    remove_index :lakeraven_ehr_audit_events, :audit_event_identifier
    remove_column :lakeraven_ehr_audit_events, :audit_event_identifier
  end
end
