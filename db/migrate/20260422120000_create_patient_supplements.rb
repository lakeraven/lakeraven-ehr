# frozen_string_literal: true

class CreatePatientSupplements < ActiveRecord::Migration[8.1]
  def change
    create_table :lakeraven_ehr_patient_supplements do |t|
      t.integer :patient_dfn, null: false
      t.string :sexual_orientation
      t.string :gender_identity
      t.timestamps
    end

    add_index :lakeraven_ehr_patient_supplements, :patient_dfn, unique: true
  end
end
