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

ActiveRecord::Schema[8.1].define(version: 2026_04_22_120000) do
  create_table "lakeraven_ehr_audit_events", force: :cascade do |t|
    t.string "action", null: false
    t.string "agent_who_identifier"
    t.string "agent_who_type"
    t.datetime "created_at", null: false
    t.string "entity_identifier"
    t.string "entity_type"
    t.string "event_type", null: false
    t.string "facility_identifier"
    t.string "outcome", null: false
    t.string "tenant_identifier"
    t.datetime "updated_at", null: false
    t.index [ "created_at" ], name: "index_lakeraven_ehr_audit_events_on_created_at"
    t.index [ "entity_type" ], name: "index_lakeraven_ehr_audit_events_on_entity_type"
    t.index [ "tenant_identifier" ], name: "index_lakeraven_ehr_audit_events_on_tenant_identifier"
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
    t.datetime "created_at", null: false
    t.integer "expires_in"
    t.string "previous_refresh_token", default: "", null: false
    t.string "refresh_token"
    t.integer "resource_owner_id"
    t.datetime "revoked_at"
    t.string "scopes"
    t.string "token", null: false
    t.index [ "application_id" ], name: "index_oauth_access_tokens_on_application_id"
    t.index [ "refresh_token" ], name: "index_oauth_access_tokens_on_refresh_token", unique: true
    t.index [ "resource_owner_id" ], name: "index_oauth_access_tokens_on_resource_owner_id"
    t.index [ "token" ], name: "index_oauth_access_tokens_on_token", unique: true
  end

  create_table "oauth_applications", force: :cascade do |t|
    t.boolean "confidential", default: true, null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.text "redirect_uri", null: false
    t.string "scopes", default: "", null: false
    t.string "secret", null: false
    t.string "uid", null: false
    t.datetime "updated_at", null: false
    t.index [ "uid" ], name: "index_oauth_applications_on_uid", unique: true
  end

  add_foreign_key "oauth_access_grants", "oauth_applications", column: "application_id"
  add_foreign_key "oauth_access_tokens", "oauth_applications", column: "application_id"
end
