# frozen_string_literal: true

# DIVERGENCE FLAG: RPMS keeps behavioral-health treatment plans in file
# 9002011.56. These tables are OUR design, not that file. Plan content stays in
# the engine's own store so a later Part 2 boundary can still be drawn around
# it (#560); see Lakeraven::EHR::TreatmentPlan.
class CreateTreatmentPlans < ActiveRecord::Migration[8.1]
  def change
    create_table :lakeraven_ehr_treatment_plans do |t|
      t.integer :patient_dfn, null: false
      t.date    :established_on, null: false
      # DUZ of the provider the plan is assigned to.
      t.string  :designated_provider, null: false
      # Always present: a plan with no due date could never be overdue, and
      # absence of a date must not read as compliance.
      t.date    :progress_review_due_on, null: false
      t.date    :end_of_treatment_review_due_on
      t.string  :concurring_supervisor
      t.datetime :supervisor_concurred_at
      t.date    :ended_on
      t.jsonb   :problems_and_goals, null: false, default: []
      t.text    :narrative
      t.timestamps

      t.check_constraint "progress_review_due_on > established_on",
                         name: "treatment_plan_review_due_after_establishment"
      t.check_constraint "end_of_treatment_review_due_on IS NULL " \
                         "OR end_of_treatment_review_due_on >= established_on",
                         name: "treatment_plan_end_review_not_before_establishment"
      t.check_constraint "ended_on IS NULL OR ended_on >= established_on",
                         name: "treatment_plan_not_ended_before_establishment"
      # Concurrence is who AND when, or nothing.
      t.check_constraint "(concurring_supervisor IS NULL) = (supervisor_concurred_at IS NULL)",
                         name: "treatment_plan_concurrence_is_complete"
      # Agreeing with your own plan is not a second clinician's concurrence.
      t.check_constraint "concurring_supervisor IS NULL OR concurring_supervisor <> designated_provider",
                         name: "treatment_plan_concurrence_by_another_clinician"
    end

    add_index :lakeraven_ehr_treatment_plans, :patient_dfn
    # The overdue worklist reads open plans by due date.
    add_index :lakeraven_ehr_treatment_plans, :progress_review_due_on,
              where: "ended_on IS NULL",
              name: "index_lakeraven_ehr_treatment_plans_open_by_review_due"

    create_table :lakeraven_ehr_treatment_plan_reviews do |t|
      t.references :treatment_plan, null: false,
                   foreign_key: { to_table: :lakeraven_ehr_treatment_plans },
                   index: { name: "index_lakeraven_ehr_treatment_plan_reviews_on_plan" }
      t.date   :reviewed_on, null: false
      t.string :reviewed_by, null: false
      t.timestamps
    end
  end
end
