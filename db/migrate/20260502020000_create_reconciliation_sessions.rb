# frozen_string_literal: true

class CreateReconciliationSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :lakeraven_ehr_reconciliation_sessions do |t|
      t.string :patient_dfn, null: false
      t.string :clinician_duz, null: false
      t.string :source_type
      t.string :source_identifier
      t.string :source_description
      t.string :status, default: "pending", null: false
      t.datetime :started_at
      t.datetime :completed_at
      t.text :raw_document
      t.timestamps
    end

    add_index :lakeraven_ehr_reconciliation_sessions, :patient_dfn
    add_index :lakeraven_ehr_reconciliation_sessions, :clinician_duz
    add_index :lakeraven_ehr_reconciliation_sessions, :status
  end
end
