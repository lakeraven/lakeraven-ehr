# frozen_string_literal: true

# Inbound ServiceRequest intake (issue #256). A system/ token has no RPMS
# connection (ADR 0011), so the referral waits here for staff triage and
# patient matching. This slice does not write RPMS or RCIS.
#
# Identifier uniqueness is per OAuth client. oauth_application_id is copied
# onto each identifier so the database can enforce that, not the model.
class CreateLakeravenEHRInboundReferrals < ActiveRecord::Migration[8.1]
  def change
    create_table :lakeraven_ehr_inbound_referrals do |t|
      t.string :public_id, null: false
      t.integer :oauth_application_id, null: false
      t.string :organization_id
      t.string :status, null: false, default: "received"
      t.string :patient_identifier_system, null: false
      t.string :patient_identifier_value, null: false
      t.jsonb :resource, null: false
      t.timestamps
    end
    add_index :lakeraven_ehr_inbound_referrals, :public_id, unique: true
    add_index :lakeraven_ehr_inbound_referrals, :oauth_application_id

    create_table :lakeraven_ehr_inbound_referral_identifiers do |t|
      t.references :inbound_referral, null: false,
                   foreign_key: { to_table: :lakeraven_ehr_inbound_referrals },
                   index: { name: "index_ehr_inbound_ref_identifiers_on_referral_id" }
      t.integer :oauth_application_id, null: false
      t.string :system, null: false
      t.string :value, null: false
      t.timestamps
    end
    add_index :lakeraven_ehr_inbound_referral_identifiers,
              %i[oauth_application_id system value],
              unique: true,
              name: "index_ehr_inbound_ref_ids_on_app_system_value"
  end
end
