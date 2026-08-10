# frozen_string_literal: true

# Durable, idempotent log of field-client sync operations. Each operation an
# offline iPad captured is reconciled server-authoritatively on reconnect
# (see FieldSyncService). Rows with outcome "conflict" are the reconciliation
# queue a clinician resolves; the log itself is the idempotency ledger that
# makes retries on flaky cellular safe (#418, #399, #410).
class CreateFieldSyncOperations < ActiveRecord::Migration[8.1]
  def change
    create_table :lakeraven_ehr_field_sync_operations do |t|
      # Client-generated idempotency key. Unique so a replayed batch cannot
      # double-apply an operation.
      t.string :client_op_id, null: false
      t.string :batch_id

      t.string :device_id
      t.string :clinician_duz
      t.string :site_ien

      t.string :operation_type, null: false # create | update
      t.string :target_type, null: false    # e.g. FieldLabTracking
      t.string :target_id                    # server id, for updates
      t.integer :base_version                # version the client derived from

      t.jsonb :payload, default: {}

      # Reconciliation outcome. pending until reconciled.
      t.string :outcome, default: "pending", null: false
      t.string :outcome_reason
      t.string :server_resource_id
      t.integer :server_version

      # Conflicts stay unresolved until a clinician reconciles them.
      t.boolean :resolved, default: false, null: false

      t.datetime :client_recorded_at

      t.timestamps
    end

    add_index :lakeraven_ehr_field_sync_operations, :client_op_id, unique: true
    add_index :lakeraven_ehr_field_sync_operations, :batch_id
    add_index :lakeraven_ehr_field_sync_operations, :outcome
    add_index :lakeraven_ehr_field_sync_operations, %i[target_type resolved]
  end
end
