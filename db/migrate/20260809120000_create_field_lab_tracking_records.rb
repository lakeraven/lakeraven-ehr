# frozen_string_literal: true

# Field lab confirmation tracking — one record follows a street-medicine
# encounter from screening → confirmation order → confirmation result →
# treatment, so the confirmation drop-off (see #418) is visible and
# actionable rather than lost on paper.
class CreateFieldLabTrackingRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :lakeraven_ehr_field_lab_tracking_records do |t|
      # Patient identity. patient_ref may be a resolved DFN or a transient
      # panel id when MPI matching has not yet run (#394); resolution is a
      # deferred follow-up, so this is a string, not an integer FK.
      t.string :patient_ref, null: false
      t.string :encounter_ref
      t.string :site_ien
      t.string :clinician_duz

      # What is being screened/confirmed (e.g. HCV, HIV, syphilis).
      t.string :condition

      # Stage machine. Server-authoritative; advanced only through guarded
      # transitions in the model (no AASM — remote-owned state).
      t.string :stage, default: "screened", null: false

      # Screening (field rapid test).
      t.string :screening_test
      t.string :screening_result
      t.datetime :screening_recorded_at

      # Confirmation order (the draw the evidence says gets dropped).
      t.string :confirmation_loinc
      t.string :confirmation_order_ref
      t.datetime :confirmation_ordered_at

      # Confirmation result.
      t.string :confirmation_result_value
      t.string :confirmation_result_status
      t.datetime :confirmation_resulted_at

      # Treatment.
      t.string :treatment_medication
      t.datetime :treatment_started_at

      # Optimistic-concurrency version, incremented on every stage transition.
      # Field clients carry the version they synced from; the sync service
      # compares it against this to detect conflicts (see FieldSyncService).
      t.integer :version, default: 1, null: false

      t.string :source, default: "field"
      t.jsonb :details, default: {}

      t.timestamps
    end

    add_index :lakeraven_ehr_field_lab_tracking_records, :patient_ref
    add_index :lakeraven_ehr_field_lab_tracking_records, :stage
    add_index :lakeraven_ehr_field_lab_tracking_records, :site_ien
  end
end
