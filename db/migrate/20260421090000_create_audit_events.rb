# frozen_string_literal: true

class CreateAuditEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :lakeraven_ehr_audit_events do |t|
      t.string :event_type, null: false
      t.string :action, null: false
      t.string :outcome, null: false
      t.string :entity_type
      t.string :entity_identifier
      t.string :agent_who_type
      t.string :agent_who_identifier
      t.string :tenant_identifier
      t.string :facility_identifier
      t.timestamps
    end

    add_index :lakeraven_ehr_audit_events, :created_at
    add_index :lakeraven_ehr_audit_events, :entity_type
    add_index :lakeraven_ehr_audit_events, :tenant_identifier
  end
end
