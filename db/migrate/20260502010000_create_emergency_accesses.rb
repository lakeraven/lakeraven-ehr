# frozen_string_literal: true

class CreateEmergencyAccesses < ActiveRecord::Migration[8.1]
  def change
    create_table :lakeraven_ehr_emergency_accesses do |t|
      t.string :patient_dfn, null: false
      t.string :accessed_by, null: false
      t.string :accessed_by_name
      t.string :reason, null: false
      t.text :justification, null: false
      t.datetime :accessed_at, null: false
      t.datetime :expires_at, null: false
      t.string :reviewed_by
      t.string :reviewed_by_name
      t.datetime :reviewed_at
      t.string :review_outcome
      t.text :review_notes
      t.timestamps
    end

    add_index :lakeraven_ehr_emergency_accesses, :patient_dfn
    add_index :lakeraven_ehr_emergency_accesses, :accessed_by
    add_index :lakeraven_ehr_emergency_accesses, :expires_at
  end
end
