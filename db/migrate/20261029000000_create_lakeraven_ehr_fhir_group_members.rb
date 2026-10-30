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

      # The same id grammar as Group#show, in the database: insert_all and
      # update_column skip the model, and a bad id must not be stored.
      # group_id is 1-64 of [A-Za-z0-9.-]. patient_dfn is a positive
      # integer string with no leading zero.
      t.check_constraint "group_id ~ '^[A-Za-z0-9.-]{1,64}$'",
                         name: "fhir_group_member_group_id_fhir_id"
      t.check_constraint "patient_dfn ~ '^[1-9][0-9]*$'",
                         name: "fhir_group_member_patient_dfn_format"
    end

    add_index :lakeraven_ehr_fhir_group_members, %i[group_id patient_dfn],
              unique: true,
              name: "index_lakeraven_ehr_fhir_group_members_on_group_patient"
  end
end
