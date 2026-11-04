# frozen_string_literal: true

# One SMART App Launch authorization (#839): what a signed-in RPMS user
# approved for a client, the one-time code the client swaps for a token, and
# the browser session the token stays bound to (#844).
#
# The code itself is never stored, only its SHA-256 digest. The user's DUZ and
# the browser session's token id are what bind a launched token to the user's
# own RPMS connection (ADR 0011): the token reads RPMS on that connection, and
# dies when that session does.
class CreateSmartAuthorizations < ActiveRecord::Migration[8.1]
  def change
    create_table :lakeraven_ehr_smart_authorizations do |t|
      t.string :code_digest, null: false, index: { unique: true }
      t.integer :application_id, null: false, index: true
      t.text :redirect_uri, null: false
      t.string :code_challenge, null: false
      t.string :scopes, null: false, default: ""
      t.string :duz, null: false
      t.string :user_name
      t.integer :session_token_id, null: false, index: true
      t.string :rpms_session_id
      t.integer :rpms_idle_seconds
      t.string :patient_dfn
      t.string :encounter_id
      t.boolean :need_patient_banner, null: false, default: false
      t.datetime :expires_at, null: false
      t.datetime :redeemed_at
      t.integer :access_token_id, index: { unique: true }
      t.timestamps
    end
  end
end
