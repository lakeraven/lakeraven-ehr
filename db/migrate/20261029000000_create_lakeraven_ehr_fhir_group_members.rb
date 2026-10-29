# frozen_string_literal: true

# Cohort membership for a FHIR Group (#216). RPMS has no Group resource, so
# bulk-export cohorts are recorded here. Group#show builds member references
# from these rows.
class CreateLakeravenEHRFHIRGroupMembers < ActiveRecord::Migration[8.1]
  def change
    create_table :lakeraven_ehr_fhir_group_members do |t|
      t.string :group_id, null: false
      t.string :patient_dfn, null: false

      t.timestamps
    end

    add_index :lakeraven_ehr_fhir_group_members, %i[group_id patient_dfn],
              unique: true,
              name: "index_lakeraven_ehr_fhir_group_members_on_group_patient"
  end
end
