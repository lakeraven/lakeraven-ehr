# frozen_string_literal: true

class CreateScreeningResponses < ActiveRecord::Migration[8.1]
  def change
    create_table :lakeraven_ehr_screening_responses do |t|
      t.integer  :patient_dfn, null: false
      t.string   :encounter_ien
      t.string   :instrument_key, null: false
      # Item-level answers, { loinc_link_id => ordinal }. Discrete, not prose —
      # the QuestionnaireResponse is rebuilt from this, never from free text.
      t.jsonb    :answers, null: false, default: {}
      t.integer  :total_score, null: false
      t.string   :severity_band, null: false
      # Effective time of the administration, so the score trends as a proper
      # Observation rather than being pinned to when the row happened to be written.
      t.datetime :effective_at, null: false
      t.string   :administered_by
      t.string   :source, null: false, default: "clinician"
      t.boolean  :safety_flagged, null: false, default: false
      # Acknowledgement evidence for a self-harm disclosure. A flagged row only
      # exists because someone acknowledged the safety prompt, so it must say
      # WHEN — and, for a clinician administration, by WHOM (a pre-visit
      # self-report, #471, has no clinician).
      #
      # These arrived as a follow-up migration during review and are folded in
      # here deliberately: the table is introduced by this same unmerged PR, so
      # there is no deployed data to migrate, and a separate `add_column` would
      # have stranded every flagged row written between the two migrations with
      # no acknowledgement trace and no way to acquire one.
      t.datetime :safety_acknowledged_at
      t.string   :safety_acknowledged_by
      # The SUBMISSION this row came from, so that one submission arriving
      # twice — a double-tap, a back-button replay, a retried POST — cannot
      # become two administrations, while an instrument genuinely
      # re-administered later the same day still can. Null for callers that
      # supply no token; Postgres treats nulls as distinct, so those are simply
      # never deduplicated.
      t.string   :submission_token
      t.timestamps

      # ALL THREE invariants in the database, not only in the model, because
      # "whoever writes it — a console, an import, a future service, a restore"
      # is a claim only the database can make good on.
      #
      # 1. A flagged row carries WHEN it was acknowledged.
      t.check_constraint "NOT safety_flagged OR safety_acknowledged_at IS NOT NULL",
                         name: "screening_flagged_requires_acknowledgement"
      # 2. A flagged CLINICIAN administration carries WHO acknowledged it. A
      #    pre-visit self-report (#471) has no clinician by definition.
      t.check_constraint "NOT (safety_flagged AND source = 'clinician') " \
                         "OR safety_acknowledged_by IS NOT NULL",
                         name: "screening_clinician_flag_requires_acknowledger"
      # 3. Answers that DISCLOSE self-harm cannot be stored unflagged — the
      #    direction that matters, since an unflagged disclosure is invisible
      #    rather than merely unattributed.
      #
      #    Fail-closed by construction: the item counts as disclosing unless it
      #    is absent, blank or a plain zero, so junk ("banana", "-1") is treated
      #    as a disclosure by the database and rejected. The model is stricter
      #    still — it requires a value the instrument actually defines.
      #
      #    The instrument key and safety item are LITERAL here (app constants
      #    do not belong in a migration); they mirror
      #    ScreeningInstrument::PHQ9.safety_link_id, and
      #    ScreeningResponseTest#"every instrument with a safety item is
      #    covered by the database constraint" fails if a new safety-bearing
      #    instrument is added without extending this.
      t.check_constraint <<~SQL.squish, name: "screening_disclosure_requires_flag"
        safety_flagged
        OR NOT (
          instrument_key = 'phq-9'
          AND answers ? '44260-8'
          AND COALESCE(answers ->> '44260-8', '') !~ '^\\s*[+-]?0*\\s*$'
        )
      SQL
    end

    # Trending reads are always "this patient, this instrument, over time".
    add_index :lakeraven_ehr_screening_responses,
              %i[patient_dfn instrument_key effective_at],
              name: "index_lakeraven_ehr_screenings_on_patient_instrument_time"
    add_index :lakeraven_ehr_screening_responses, :encounter_ien
    # THE dedupe rule, enforced by the database rather than by a check-then-
    # insert that two concurrent requests can both pass.
    add_index :lakeraven_ehr_screening_responses, :submission_token,
              unique: true, name: "index_lakeraven_ehr_screenings_on_submission_token"
  end
end
