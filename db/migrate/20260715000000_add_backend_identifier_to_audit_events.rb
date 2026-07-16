# frozen_string_literal: true

class AddBackendIdentifierToAuditEvents < ActiveRecord::Migration[8.0]
  def change
    add_column :lakeraven_ehr_audit_events, :backend_identifier, :string
  end
end
