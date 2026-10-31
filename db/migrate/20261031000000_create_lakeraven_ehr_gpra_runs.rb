# frozen_string_literal: true

# The site's GPRA report, computed by rook over a FHIR population (#780). A run
# is derived from RPMS data and kept so the homepage reads a finished report
# instead of computing measures on request; RPMS has no place for this engine's
# measure results.
#
# A run keeps per-measure counts and rook's summary MeasureReport. Its care gaps
# name a patient by DFN, the measure, and rook's reason only: no names or
# clinical values, which the care-gap list reads from RPMS when it is opened.
class CreateLakeravenEHRGpraRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :lakeraven_ehr_gpra_runs do |t|
      t.date :period_start, null: false
      t.date :period_end, null: false
      # running, succeeded, failed
      t.string :status, null: false
      t.datetime :started_at, null: false
      t.datetime :finished_at
      # The error's class only: a message could carry patient data.
      t.string :error_class
      # One entry per measure: id, title, interpretation, improvement notation,
      # denominator, numerator, rate and the summary MeasureReport.
      t.jsonb :measures, null: false, default: []
      t.timestamps
    end
    add_index :lakeraven_ehr_gpra_runs, %i[status finished_at]

    create_table :lakeraven_ehr_gpra_care_gaps do |t|
      t.references :gpra_run, null: false, index: false, foreign_key: { to_table: :lakeraven_ehr_gpra_runs, on_delete: :cascade }
      t.string :measure_id, null: false
      t.string :patient_dfn, null: false
      t.string :reason, null: false
    end
    add_index :lakeraven_ehr_gpra_care_gaps, %i[gpra_run_id measure_id], name: "index_lakeraven_ehr_gpra_care_gaps_on_run_and_measure"
  end
end
