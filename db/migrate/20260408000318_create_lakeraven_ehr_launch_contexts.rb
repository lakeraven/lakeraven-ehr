# frozen_string_literal: true

class CreateLakeravenEHRLaunchContexts < ActiveRecord::Migration[8.1]
  def change
    create_table :lakeraven_ehr_launch_contexts do |t|
      t.string :launch_token, null: false
      t.string :patient_identifier, null: false
      t.string :tenant_identifier, null: false
      t.string :facility_identifier
      t.string :encounter_identifier
      t.datetime :expires_at, null: false

      t.timestamps
    end

    add_index :lakeraven_ehr_launch_contexts, :launch_token, unique: true
    add_index :lakeraven_ehr_launch_contexts, :tenant_identifier
  end
end
