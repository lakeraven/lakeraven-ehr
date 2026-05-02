# frozen_string_literal: true

class CreateReconciliationItems < ActiveRecord::Migration[8.1]
  def change
    create_table :lakeraven_ehr_reconciliation_items do |t|
      t.references :reconciliation_session, null: false,
                   foreign_key: { to_table: :lakeraven_ehr_reconciliation_sessions }
      t.string :resource_type, null: false
      t.string :match_status, null: false
      t.string :decision, default: "pending", null: false
      t.string :decided_by_duz
      t.datetime :decided_at
      t.jsonb :external_data, default: {}
      t.jsonb :internal_data, default: {}
      t.string :external_code
      t.string :external_code_system
      t.string :external_display
      t.string :internal_ien
      t.boolean :write_back_completed, default: false
      t.string :write_back_error
      t.timestamps
    end

    add_index :lakeraven_ehr_reconciliation_items, :resource_type
    add_index :lakeraven_ehr_reconciliation_items, :decision
  end
end
