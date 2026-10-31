# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_31_000000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "lakeraven_ehr_amendment_requests", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description", null: false
    t.string "patient_dfn", null: false
    t.text "reason", null: false
    t.string "requested_by", null: false
    t.string "resource_id"
    t.string "resource_type", null: false
    t.text "review_reason"
    t.datetime "reviewed_at"
    t.string "reviewed_by"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index [ "patient_dfn" ], name: "index_lakeraven_ehr_amendment_requests_on_patient_dfn"
    t.index [ "status" ], name: "index_lakeraven_ehr_amendment_requests_on_status"
  end

  create_table "lakeraven_ehr_audit_events", force: :cascade do |t|
    t.string "action", null: false
    t.string "agent_name"
    t.string "agent_network_address"
    t.string "agent_who_identifier"
    t.string "agent_who_type"
    t.datetime "created_at", null: false
    t.string "entity_id"
    t.string "entity_identifier"
    t.string "entity_type"
    t.string "event_type", null: false
    t.string "facility_identifier"
    t.string "outcome", null: false
    t.text "outcome_desc"
    t.string "rpms_session_id"
    t.string "tenant_identifier"
    t.datetime "updated_at", null: false
    t.index [ "created_at" ], name: "index_lakeraven_ehr_audit_events_on_created_at"
    t.index [ "entity_type" ], name: "index_lakeraven_ehr_audit_events_on_entity_type"
    t.index [ "tenant_identifier" ], name: "index_lakeraven_ehr_audit_events_on_tenant_identifier"
  end

  create_table "lakeraven_ehr_backend_assertion_jtis", force: :cascade do |t|
    t.string "client_id", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "jti", null: false
    t.index [ "client_id", "jti" ], name: "idx_backend_assertion_jti_uniqueness", unique: true
    t.index [ "expires_at" ], name: "index_lakeraven_ehr_backend_assertion_jtis_on_expires_at"
  end

  create_table "lakeraven_ehr_behavioral_health_visit_codings", force: :cascade do |t|
    t.string "cpt_code"
    t.datetime "created_at", null: false
    t.string "documented_by_duz", null: false
    t.integer "duration_minutes"
    t.string "encounter_ien", null: false
    t.string "encounter_kind", null: false
    t.integer "patient_dfn", null: false
    t.string "selected_cpt_code"
    t.datetime "updated_at", null: false
    t.index [ "patient_dfn", "encounter_ien" ], name: "index_lakeraven_ehr_bh_visit_codings_on_patient_encounter", unique: true
    t.check_constraint "(encounter_kind::text = 'psychiatric_diagnostic_evaluation'::text AND NOT cpt_code::text IS DISTINCT FROM '90791'::text AND (selected_cpt_code IS NULL OR selected_cpt_code::text = '90791'::text) AND (duration_minutes IS NULL OR duration_minutes >= 0) OR encounter_kind::text = 'individual_psychotherapy'::text AND duration_minutes IS NOT NULL AND duration_minutes > 0 AND (selected_cpt_code IS NULL OR (selected_cpt_code::text = ANY (ARRAY['90832'::character varying, '90834'::character varying, '90837'::character varying]::text[]))) AND (duration_minutes < 16 AND cpt_code IS NULL OR duration_minutes >= 16 AND duration_minutes <= 37 AND ((selected_cpt_code IS NULL OR selected_cpt_code::text = '90832'::text) AND NOT cpt_code::text IS DISTINCT FROM '90832'::text OR selected_cpt_code IS NOT NULL AND selected_cpt_code::text <> '90832'::text AND cpt_code IS NULL) OR duration_minutes >= 38 AND duration_minutes <= 52 AND ((selected_cpt_code IS NULL OR selected_cpt_code::text = '90834'::text) AND NOT cpt_code::text IS DISTINCT FROM '90834'::text OR selected_cpt_code IS NOT NULL AND selected_cpt_code::text <> '90834'::text AND cpt_code IS NULL) OR duration_minutes >= 53 AND ((selected_cpt_code IS NULL OR selected_cpt_code::text = '90837'::text) AND NOT cpt_code::text IS DISTINCT FROM '90837'::text OR selected_cpt_code IS NOT NULL AND selected_cpt_code::text <> '90837'::text AND cpt_code IS NULL))) IS TRUE", name: "bh_visit_coding_duration_and_cpt_consistent"
  end

  create_table "lakeraven_ehr_bh_program_configurations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "end_of_treatment_review_interval_parts", null: false
    t.string "program_key", null: false
    t.jsonb "progress_review_interval_parts", null: false
    t.datetime "updated_at", null: false
    t.index [ "program_key" ], name: "index_ehr_bh_program_configs_on_program_key", unique: true
  end

  create_table "lakeraven_ehr_disclosures", force: :cascade do |t|
    t.string "authorization_method"
    t.string "consent_reference"
    t.datetime "created_at", null: false
    t.text "data_disclosed", null: false
    t.datetime "disclosed_at", null: false
    t.string "disclosed_by", null: false
    t.string "disclosed_by_name"
    t.string "patient_dfn", null: false
    t.string "purpose", null: false
    t.string "recipient_name", null: false
    t.string "recipient_npi"
    t.string "recipient_type"
    t.datetime "updated_at", null: false
    t.index [ "disclosed_at" ], name: "index_lakeraven_ehr_disclosures_on_disclosed_at"
    t.index [ "patient_dfn" ], name: "index_lakeraven_ehr_disclosures_on_patient_dfn"
  end

  create_table "lakeraven_ehr_emergency_accesses", force: :cascade do |t|
    t.datetime "accessed_at", null: false
    t.string "accessed_by", null: false
    t.string "accessed_by_name"
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.text "justification", null: false
    t.string "patient_dfn", null: false
    t.string "reason", null: false
    t.text "review_notes"
    t.string "review_outcome"
    t.datetime "reviewed_at"
    t.string "reviewed_by"
    t.string "reviewed_by_name"
    t.datetime "updated_at", null: false
    t.index [ "accessed_by" ], name: "index_lakeraven_ehr_emergency_accesses_on_accessed_by"
    t.index [ "expires_at" ], name: "index_lakeraven_ehr_emergency_accesses_on_expires_at"
    t.index [ "patient_dfn" ], name: "index_lakeraven_ehr_emergency_accesses_on_patient_dfn"
  end

  create_table "lakeraven_ehr_gpra_care_gaps", force: :cascade do |t|
    t.bigint "gpra_run_id", null: false
    t.string "measure_id", null: false
    t.string "patient_dfn", null: false
    t.string "reason", null: false
    t.index [ "gpra_run_id", "measure_id" ], name: "index_lakeraven_ehr_gpra_care_gaps_on_run_and_measure"
  end

  create_table "lakeraven_ehr_gpra_runs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "error_class"
    t.datetime "finished_at"
    t.jsonb "measures", default: [], null: false
    t.date "period_end", null: false
    t.date "period_start", null: false
    t.datetime "started_at", null: false
    t.string "status", null: false
    t.datetime "updated_at", null: false
    t.index [ "status", "finished_at" ], name: "index_lakeraven_ehr_gpra_runs_on_status_and_finished_at"
  end

  create_table "lakeraven_ehr_launch_contexts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "encounter_id"
    t.datetime "expires_at", null: false
    t.string "facility_identifier"
    t.string "launch_token", null: false
    t.string "oauth_application_uid", null: false
    t.string "patient_dfn"
    t.datetime "updated_at", null: false
    t.index [ "launch_token" ], name: "index_lakeraven_ehr_launch_contexts_on_launch_token", unique: true
  end

  create_table "lakeraven_ehr_patient_supplements", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "gender_identity"
    t.integer "patient_dfn", null: false
    t.string "sexual_orientation"
    t.datetime "updated_at", null: false
    t.index [ "patient_dfn" ], name: "index_lakeraven_ehr_patient_supplements_on_patient_dfn", unique: true
  end

  create_table "lakeraven_ehr_reconciliation_items", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "decided_at"
    t.string "decided_by_duz"
    t.string "decision", default: "pending", null: false
    t.string "external_code"
    t.string "external_code_system"
    t.jsonb "external_data", default: {}
    t.string "external_display"
    t.jsonb "internal_data", default: {}
    t.string "internal_ien"
    t.string "match_status", null: false
    t.bigint "reconciliation_session_id", null: false
    t.string "resource_type", null: false
    t.datetime "updated_at", null: false
    t.boolean "write_back_completed", default: false
    t.string "write_back_error"
    t.index [ "decision" ], name: "index_lakeraven_ehr_reconciliation_items_on_decision"
    t.index [ "reconciliation_session_id" ], name: "idx_on_reconciliation_session_id_5031b9cf3c"
    t.index [ "resource_type" ], name: "index_lakeraven_ehr_reconciliation_items_on_resource_type"
  end

  create_table "lakeraven_ehr_reconciliation_sessions", force: :cascade do |t|
    t.string "clinician_duz", null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.string "patient_dfn", null: false
    t.text "raw_document"
    t.string "source_description"
    t.string "source_identifier"
    t.string "source_type"
    t.datetime "started_at"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index [ "clinician_duz" ], name: "index_lakeraven_ehr_reconciliation_sessions_on_clinician_duz"
    t.index [ "patient_dfn" ], name: "index_lakeraven_ehr_reconciliation_sessions_on_patient_dfn"
    t.index [ "status" ], name: "index_lakeraven_ehr_reconciliation_sessions_on_status"
  end

  create_table "lakeraven_ehr_registration_reviews", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "duz", null: false
    t.string "review_id", null: false
    t.index [ "review_id" ], name: "index_lakeraven_ehr_registration_reviews_on_review_id", unique: true
  end

  create_table "lakeraven_ehr_screening_responses", force: :cascade do |t|
    t.string "administered_by"
    t.jsonb "answers", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "effective_at", null: false
    t.string "encounter_ien"
    t.string "instrument_key", null: false
    t.integer "patient_dfn", null: false
    t.datetime "safety_acknowledged_at"
    t.string "safety_acknowledged_by"
    t.boolean "safety_flagged", default: false, null: false
    t.string "severity_band", null: false
    t.string "source", default: "clinician", null: false
    t.string "submission_token"
    t.integer "total_score", null: false
    t.datetime "updated_at", null: false
    t.index [ "encounter_ien" ], name: "index_lakeraven_ehr_screening_responses_on_encounter_ien"
    t.index [ "patient_dfn", "instrument_key", "effective_at" ], name: "index_lakeraven_ehr_screenings_on_patient_instrument_time"
    t.index [ "submission_token" ], name: "index_lakeraven_ehr_screenings_on_submission_token", unique: true
    t.check_constraint "NOT (safety_flagged AND source::text = 'clinician'::text) OR safety_acknowledged_by IS NOT NULL", name: "screening_clinician_flag_requires_acknowledger"
    t.check_constraint "NOT safety_flagged OR safety_acknowledged_at IS NOT NULL", name: "screening_flagged_requires_acknowledgement"
    t.check_constraint "safety_flagged OR NOT (instrument_key::text = 'phq-9'::text AND answers ? '44260-8'::text AND COALESCE(answers ->> '44260-8'::text, ''::text) !~ '^\\s*[+-]?0*\\s*$'::text)", name: "screening_disclosure_requires_flag"
    t.check_constraint "source::text <> 'clinician'::text OR administered_by IS NOT NULL", name: "screening_clinician_requires_administrator"
  end

  create_table "lakeraven_ehr_treatment_plan_concurrences", force: :cascade do |t|
    t.datetime "concurred_at", null: false
    t.datetime "created_at", null: false
    t.string "supervisor_duz", null: false
    t.bigint "treatment_plan_id", null: false
    t.datetime "updated_at", null: false
    t.index [ "treatment_plan_id" ], name: "index_ehr_tp_concurrences_on_plan", unique: true
  end

  create_table "lakeraven_ehr_treatment_plan_progress_reviews", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.date "reviewed_on", null: false
    t.string "reviewed_by_duz", null: false
    t.bigint "treatment_plan_id", null: false
    t.datetime "updated_at", null: false
    t.index [ "treatment_plan_id" ], name: "index_ehr_tp_progress_reviews_on_plan"
  end

  create_table "lakeraven_ehr_treatment_plans", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.date "date_established", null: false
    t.string "designated_provider_duz", null: false
    t.date "end_of_treatment_review_due_on"
    t.text "narrative", null: false
    t.integer "patient_dfn", null: false
    t.jsonb "problems_goals", default: [], null: false
    t.string "program_key", null: false
    t.date "progress_review_due_on"
    t.datetime "updated_at", null: false
    t.index [ "patient_dfn" ], name: "index_lakeraven_ehr_treatment_plans_on_patient_dfn"
    t.index [ "program_key" ], name: "index_lakeraven_ehr_treatment_plans_on_program_key"
    t.index [ "progress_review_due_on" ], name: "index_lakeraven_ehr_treatment_plans_on_progress_review_due_on"
  end

  create_table "oauth_access_grants", force: :cascade do |t|
    t.integer "application_id", null: false
    t.datetime "created_at", null: false
    t.integer "expires_in", null: false
    t.text "redirect_uri", null: false
    t.integer "resource_owner_id", null: false
    t.datetime "revoked_at"
    t.string "scopes", default: "", null: false
    t.string "token", null: false
    t.index [ "application_id" ], name: "index_oauth_access_grants_on_application_id"
    t.index [ "resource_owner_id" ], name: "index_oauth_access_grants_on_resource_owner_id"
    t.index [ "token" ], name: "index_oauth_access_grants_on_token", unique: true
  end

  create_table "oauth_access_tokens", force: :cascade do |t|
    t.integer "application_id", null: false
    t.boolean "browser_session", default: false, null: false
    t.datetime "created_at", null: false
    t.integer "expires_in"
    t.string "previous_refresh_token", default: "", null: false
    t.string "refresh_token"
    t.integer "resource_owner_id"
    t.datetime "revoked_at"
    t.string "scopes"
    t.string "token", null: false
    t.index [ "application_id" ], name: "index_oauth_access_tokens_on_application_id"
    t.index [ "browser_session" ], name: "index_oauth_access_tokens_on_browser_session"
    t.index [ "refresh_token" ], name: "index_oauth_access_tokens_on_refresh_token", unique: true
    t.index [ "resource_owner_id" ], name: "index_oauth_access_tokens_on_resource_owner_id"
    t.index [ "token" ], name: "index_oauth_access_tokens_on_token", unique: true
  end

  create_table "oauth_applications", force: :cascade do |t|
    t.boolean "confidential", default: true, null: false
    t.datetime "created_at", null: false
    t.string "jwks_uri"
    t.string "name", null: false
    t.string "organization_id"
    t.text "redirect_uri", null: false
    t.string "scopes", default: "", null: false
    t.string "secret", null: false
    t.string "uid", null: false
    t.datetime "updated_at", null: false
    t.index [ "organization_id" ], name: "index_oauth_applications_on_organization_id"
    t.index [ "uid" ], name: "index_oauth_applications_on_uid", unique: true
  end

  add_foreign_key "lakeraven_ehr_gpra_care_gaps", "lakeraven_ehr_gpra_runs", column: "gpra_run_id", on_delete: :cascade
  add_foreign_key "lakeraven_ehr_reconciliation_items", "lakeraven_ehr_reconciliation_sessions", column: "reconciliation_session_id"
  add_foreign_key "lakeraven_ehr_treatment_plan_concurrences", "lakeraven_ehr_treatment_plans", column: "treatment_plan_id"
  add_foreign_key "lakeraven_ehr_treatment_plan_progress_reviews", "lakeraven_ehr_treatment_plans", column: "treatment_plan_id"
  add_foreign_key "oauth_access_grants", "oauth_applications", column: "application_id"
  add_foreign_key "oauth_access_tokens", "oauth_applications", column: "application_id"
end
