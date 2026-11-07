# frozen_string_literal: true

# The in-clinic tablet lock (#793). Owner: this engine.
#
# RPMS cannot hold it. The lock has to survive an older copy of the session
# cookie, so it is keyed by the sign-on credential those copies share, not by
# the cookie itself. The foreign key stops a revocation from naming a consent
# row that was never stored. No trigger: a saved consent stays immutable in
# the model.
class AddKioskLocksAndRevocationForeignKey < ActiveRecord::Migration[8.1]
  def change
    create_table :lakeraven_ehr_kiosk_locks do |t|
      t.string :credential_key, null: false
      t.string :patient_dfn, null: false
      t.string :template_key, null: false
      t.integer :template_version, null: false
      t.string :handover_token, null: false
      t.timestamps

      t.index :credential_key, unique: true, name: "index_lakeraven_ehr_kiosk_locks_credential_key"
      t.index :handover_token, unique: true, name: "index_lakeraven_ehr_kiosk_locks_handover_token"
    end

    add_foreign_key :lakeraven_ehr_signed_consents, :lakeraven_ehr_signed_consents,
                    column: :revokes_id, name: "fk_lakeraven_ehr_signed_consents_revokes_id"
  end
end
