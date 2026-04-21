# frozen_string_literal: true

class CreateLaunchContexts < ActiveRecord::Migration[8.1]
  def change
    create_table :lakeraven_ehr_launch_contexts do |t|
      t.string :launch_token, null: false, index: { unique: true }
      t.string :oauth_application_uid, null: false
      t.string :patient_dfn
      t.string :encounter_id
      t.string :facility_identifier
      t.datetime :expires_at, null: false
      t.timestamps
    end
  end
end
