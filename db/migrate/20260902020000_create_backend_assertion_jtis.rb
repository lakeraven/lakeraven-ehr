# frozen_string_literal: true

# Shared replay-guard state for SMART Backend Services client assertions.
# The unique (client_id, jti) index is the atomic test-and-set: the first
# INSERT wins, every other process/worker/restart sees RecordNotUnique.
class CreateBackendAssertionJtis < ActiveRecord::Migration[8.1]
  def change
    create_table :lakeraven_ehr_backend_assertion_jtis do |t|
      t.string :client_id, null: false
      t.string :jti, null: false
      t.datetime :expires_at, null: false
      t.datetime :created_at, null: false
    end
    add_index :lakeraven_ehr_backend_assertion_jtis, %i[client_id jti],
      unique: true, name: "idx_backend_assertion_jti_uniqueness"
    add_index :lakeraven_ehr_backend_assertion_jtis, :expires_at
  end
end
