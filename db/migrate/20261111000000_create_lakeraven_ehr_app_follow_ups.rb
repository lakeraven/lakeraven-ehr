# frozen_string_literal: true

# Demo prototype (#988, #989, #990; not in the December build). A follow-up a
# registered outside app posts about a referral, as a FHIR Communication, is
# held here for staff review. Nothing reaches RPMS until a person confirms it.
# Identifiers and the app's short structured result only: no audio and no
# transcript (#988).
class CreateLakeravenEHRAppFollowUps < ActiveRecord::Migration[8.1]
  def change
    create_table :lakeraven_ehr_app_follow_ups do |t|
      t.string :client_id, null: false
      t.string :app_name, null: false
      t.boolean :ai_generated, null: false, default: false
      t.integer :patient_dfn, null: false
      t.integer :referral_ien, null: false
      t.string :status, null: false, default: "pending"
      t.boolean :reached
      t.date :appointment_on
      t.string :summary, null: false, limit: 500
      t.string :reviewed_by_duz
      t.string :reviewed_by_name
      t.datetime :reviewed_at
      t.string :write_back_status
      t.string :write_back_detail
      t.json :read_back
      t.timestamps
    end
    add_index :lakeraven_ehr_app_follow_ups, :status
  end
end
