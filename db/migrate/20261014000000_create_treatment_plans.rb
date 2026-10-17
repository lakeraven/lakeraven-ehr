# frozen_string_literal: true

# Treatment plans live in the engine database. lakeraven-ehr#560 keeps them
# out of shared RPMS files, so this migration does not touch file 9002011.56
# and nothing in the model layer reaches it through an RPC.
#
# progress_review_due_on is nullable on purpose. A row with no due date is
# not evidence the review is on time; the overdue query excludes it and a
# separate scope lists it as indeterminate.
class CreateTreatmentPlans < ActiveRecord::Migration[8.1]
  def change
    create_table :lakeraven_ehr_bh_program_configurations do |t|
      t.string :program_key, null: false
      # Calendar parts, e.g. {"days" => n} or {"months" => n}. Stored as
      # parts so a month interval is still a month when it is read back.
      t.jsonb :progress_review_interval_parts, null: false
      t.jsonb :end_of_treatment_review_interval_parts, null: false
      t.timestamps
    end
    add_index :lakeraven_ehr_bh_program_configurations, :program_key,
              unique: true, name: "index_ehr_bh_program_configs_on_program_key"

    create_table :lakeraven_ehr_treatment_plans do |t|
      t.integer :patient_dfn, null: false
      t.string :program_key, null: false
      t.date :date_established, null: false
      t.string :designated_provider_duz, null: false
      t.text :narrative, null: false
      t.jsonb :problems_goals, null: false, default: []
      t.date :progress_review_due_on
      t.date :end_of_treatment_review_due_on
      t.timestamps
    end
    add_index :lakeraven_ehr_treatment_plans, :patient_dfn,
              name: "index_lakeraven_ehr_treatment_plans_on_patient_dfn"
    add_index :lakeraven_ehr_treatment_plans, :program_key,
              name: "index_lakeraven_ehr_treatment_plans_on_program_key"
    add_index :lakeraven_ehr_treatment_plans, :progress_review_due_on,
              name: "index_lakeraven_ehr_treatment_plans_on_progress_review_due_on"

    create_table :lakeraven_ehr_treatment_plan_progress_reviews do |t|
      t.references :treatment_plan, null: false,
                   index: { name: "index_ehr_tp_progress_reviews_on_plan" },
                   foreign_key: { to_table: :lakeraven_ehr_treatment_plans }
      t.date :reviewed_on, null: false
      t.string :reviewed_by_duz, null: false
      t.timestamps
    end

    create_table :lakeraven_ehr_treatment_plan_concurrences do |t|
      t.references :treatment_plan, null: false,
                   index: { unique: true, name: "index_ehr_tp_concurrences_on_plan" },
                   foreign_key: { to_table: :lakeraven_ehr_treatment_plans }
      t.string :supervisor_duz, null: false
      t.datetime :concurred_at, null: false
      t.timestamps
    end
  end
end
