# frozen_string_literal: true

class CreateBehavioralHealthVisitCodings < ActiveRecord::Migration[8.1]
  def change
    create_table :lakeraven_ehr_behavioral_health_visit_codings do |t|
      t.integer :patient_dfn, null: false
      t.string :encounter_ien, null: false
      t.string :encounter_kind, null: false
      t.integer :duration_minutes
      t.string :selected_cpt_code
      # Derived. Null when the visit is stored but not reportable.
      t.string :cpt_code
      t.string :documented_by_duz, null: false
      t.timestamps

      # The model refuses the same cases. The check is here so a console,
      # import, or later writer cannot store a code the minutes do not
      # support, or an individual visit with no positive duration.
      t.check_constraint <<~SQL.squish, name: "bh_visit_coding_duration_and_cpt_consistent"
        (
          encounter_kind = 'psychiatric_diagnostic_evaluation'
          AND cpt_code = '90791'
          AND (selected_cpt_code IS NULL OR selected_cpt_code = '90791')
        )
        OR
        (
          encounter_kind = 'individual_psychotherapy'
          AND duration_minutes > 0
          AND (selected_cpt_code IS NULL OR selected_cpt_code IN ('90832', '90834', '90837'))
          AND (
            (duration_minutes < 16 AND cpt_code IS NULL)
            OR (
              duration_minutes BETWEEN 16 AND 37
              AND (
                ((selected_cpt_code IS NULL OR selected_cpt_code = '90832') AND cpt_code = '90832')
                OR (selected_cpt_code IS NOT NULL AND selected_cpt_code <> '90832' AND cpt_code IS NULL)
              )
            )
            OR (
              duration_minutes BETWEEN 38 AND 52
              AND (
                ((selected_cpt_code IS NULL OR selected_cpt_code = '90834') AND cpt_code = '90834')
                OR (selected_cpt_code IS NOT NULL AND selected_cpt_code <> '90834' AND cpt_code IS NULL)
              )
            )
            OR (
              duration_minutes >= 53
              AND (
                ((selected_cpt_code IS NULL OR selected_cpt_code = '90837') AND cpt_code = '90837')
                OR (selected_cpt_code IS NOT NULL AND selected_cpt_code <> '90837' AND cpt_code IS NULL)
              )
            )
          )
        )
      SQL
    end

    add_index :lakeraven_ehr_behavioral_health_visit_codings,
              %i[patient_dfn encounter_ien],
              name: "index_lakeraven_ehr_bh_visit_codings_on_patient_encounter"
  end
end
