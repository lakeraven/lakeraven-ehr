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
      # Identity of the administration, so a duplicate cannot be inserted even
      # when two identical requests race past each other's lookups. Derived
      # from (patient, instrument, visit, administering clinician, answers,
      # calendar day) — see ScreeningResponse.administration_digest_for.
      t.string   :administration_digest, null: false
      t.timestamps

      # The invariant in the database, not only in the model: a flagged row
      # without acknowledgement evidence cannot exist, whoever writes it —
      # a console, an import, a future service, a restore.
      t.check_constraint "NOT safety_flagged OR safety_acknowledged_at IS NOT NULL",
                         name: "screening_flagged_requires_acknowledgement"
    end

    # Trending reads are always "this patient, this instrument, over time".
    add_index :lakeraven_ehr_screening_responses,
              %i[patient_dfn instrument_key effective_at],
              name: "index_lakeraven_ehr_screenings_on_patient_instrument_time"
    add_index :lakeraven_ehr_screening_responses, :encounter_ien
    # THE dedupe rule, enforced by the database rather than by a check-then-
    # insert that two concurrent requests can both pass.
    add_index :lakeraven_ehr_screening_responses, :administration_digest,
              unique: true, name: "index_lakeraven_ehr_screenings_on_administration_digest"
  end
end
