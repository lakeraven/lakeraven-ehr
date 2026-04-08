# frozen_string_literal: true

class CreateLakeravenEHRAuditEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :lakeraven_ehr_audit_events do |t|
      t.string :event_type, null: false
      t.string :action, null: false
      t.string :outcome, null: false
      t.datetime :recorded, null: false

      t.string :tenant_identifier, null: false
      t.string :facility_identifier

      t.string :agent_who_type, null: false
      t.string :agent_who_identifier, null: false
      t.string :agent_network_address

      t.string :entity_type
      t.string :entity_identifier

      t.string :source_observer

      t.timestamps
    end

    add_index :lakeraven_ehr_audit_events, :tenant_identifier
    add_index :lakeraven_ehr_audit_events, :recorded
    add_index :lakeraven_ehr_audit_events, [ :entity_type, :entity_identifier ], name: "index_lakeraven_ehr_audit_events_on_entity"
    add_index :lakeraven_ehr_audit_events, [ :agent_who_type, :agent_who_identifier ], name: "index_lakeraven_ehr_audit_events_on_agent"
  end
end
