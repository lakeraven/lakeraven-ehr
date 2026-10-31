# frozen_string_literal: true

# One coding row per visit, and a check that fails when a compared column
# is NULL. Postgres treats a NULL check as passing, so the original terms
# accepted an individual visit with no duration and a diagnostic evaluation
# with no CPT code.
class EnforceBehavioralHealthVisitCodingInvariants < ActiveRecord::Migration[8.1]
  TABLE = :lakeraven_ehr_behavioral_health_visit_codings
  CONSTRAINT = "bh_visit_coding_duration_and_cpt_consistent"
  INDEX = "index_lakeraven_ehr_bh_visit_codings_on_patient_encounter"

  def up
    remove_check_constraint TABLE, name: CONSTRAINT
    add_check_constraint TABLE, null_safe_check, name: CONSTRAINT
    remove_index TABLE, name: INDEX
    add_index TABLE, %i[patient_dfn encounter_ien], unique: true, name: INDEX
  end

  def down
    remove_index TABLE, name: INDEX
    add_index TABLE, %i[patient_dfn encounter_ien], name: INDEX
    remove_check_constraint TABLE, name: CONSTRAINT
    add_check_constraint TABLE, original_check, name: CONSTRAINT
  end

  private

  # `IS NOT DISTINCT FROM` is false for NULL, and `IS TRUE` makes any
  # remaining unknown fail the check. A plain `=` or `>` would pass.
  # Evaluation has no time band; a negative duration is still refused.
  # NULL and zero stay allowed.
  def null_safe_check
    <<~SQL.squish
      (
        (
          encounter_kind = 'psychiatric_diagnostic_evaluation'
          AND cpt_code IS NOT DISTINCT FROM '90791'
          AND (selected_cpt_code IS NULL OR selected_cpt_code = '90791')
          AND (duration_minutes IS NULL OR duration_minutes >= 0)
        )
        OR
        (
          encounter_kind = 'individual_psychotherapy'
          AND duration_minutes IS NOT NULL
          AND duration_minutes > 0
          AND (selected_cpt_code IS NULL OR selected_cpt_code IN ('90832', '90834', '90837'))
          AND (
            (duration_minutes < 16 AND cpt_code IS NULL)
            OR (
              duration_minutes BETWEEN 16 AND 37
              AND (
                (
                  (selected_cpt_code IS NULL OR selected_cpt_code = '90832')
                  AND cpt_code IS NOT DISTINCT FROM '90832'
                )
                OR (
                  selected_cpt_code IS NOT NULL
                  AND selected_cpt_code <> '90832'
                  AND cpt_code IS NULL
                )
              )
            )
            OR (
              duration_minutes BETWEEN 38 AND 52
              AND (
                (
                  (selected_cpt_code IS NULL OR selected_cpt_code = '90834')
                  AND cpt_code IS NOT DISTINCT FROM '90834'
                )
                OR (
                  selected_cpt_code IS NOT NULL
                  AND selected_cpt_code <> '90834'
                  AND cpt_code IS NULL
                )
              )
            )
            OR (
              duration_minutes >= 53
              AND (
                (
                  (selected_cpt_code IS NULL OR selected_cpt_code = '90837')
                  AND cpt_code IS NOT DISTINCT FROM '90837'
                )
                OR (
                  selected_cpt_code IS NOT NULL
                  AND selected_cpt_code <> '90837'
                  AND cpt_code IS NULL
                )
              )
            )
          )
        )
      ) IS TRUE
    SQL
  end

  def original_check
    <<~SQL.squish
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
end
