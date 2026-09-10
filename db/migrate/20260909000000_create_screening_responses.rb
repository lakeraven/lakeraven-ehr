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
      t.timestamps
    end

    # Trending reads are always "this patient, this instrument, over time".
    add_index :lakeraven_ehr_screening_responses,
              %i[patient_dfn instrument_key effective_at],
              name: "index_lakeraven_ehr_screenings_on_patient_instrument_time"
    add_index :lakeraven_ehr_screening_responses, :encounter_ien
  end
end
