# frozen_string_literal: true

class CreateDisclosures < ActiveRecord::Migration[8.1]
  def change
    create_table :lakeraven_ehr_disclosures do |t|
      t.string :patient_dfn, null: false
      t.string :recipient_name, null: false
      t.string :recipient_type
      t.string :recipient_npi
      t.string :purpose, null: false
      t.text :data_disclosed, null: false
      t.string :disclosed_by, null: false
      t.string :disclosed_by_name
      t.datetime :disclosed_at, null: false
      t.string :authorization_method
      t.string :consent_reference
      t.timestamps
    end

    add_index :lakeraven_ehr_disclosures, :patient_dfn
    add_index :lakeraven_ehr_disclosures, :disclosed_at
  end
end
