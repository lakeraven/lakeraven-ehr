# frozen_string_literal: true

class AddAuditEventDetails < ActiveRecord::Migration[8.1]
  def change
    add_column :lakeraven_ehr_audit_events, :outcome_desc, :text
    add_column :lakeraven_ehr_audit_events, :agent_name, :string
    add_column :lakeraven_ehr_audit_events, :agent_network_address, :string
    add_column :lakeraven_ehr_audit_events, :entity_id, :string
  end
end
