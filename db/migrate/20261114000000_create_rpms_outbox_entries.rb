# frozen_string_literal: true

# Transactional outbox for side effects bound for RPMS (#997). A row is
# written in the same transaction as the change that caused it and is
# delivered later by RpmsOutboxDispatchJob. The unique idempotency_key makes
# a repeated enqueue a no-op; the partial (status, next_attempt_at) index over
# pending rows serves the dispatcher's claim query. Error metadata is the
# error class only: no message or backtrace column, so no PHI lands on the row.
class CreateRpmsOutboxEntries < ActiveRecord::Migration[8.1]
  TABLE = :lakeraven_ehr_rpms_outbox_entries

  def change
    create_table TABLE do |t|
      t.string :effect, null: false
      t.string :idempotency_key, null: false
      t.jsonb :payload, null: false, default: {}
      t.string :status, null: false, default: "pending"
      t.integer :attempts, null: false, default: 0
      t.datetime :next_attempt_at, null: false
      t.datetime :last_attempted_at
      t.string :last_error_class
      t.datetime :delivered_at
      t.datetime :dead_lettered_at
      t.timestamps
    end
    add_index TABLE, :idempotency_key, unique: true, name: "idx_rpms_outbox_idempotency_key"
    add_index TABLE, %i[status next_attempt_at], name: "idx_rpms_outbox_claim", where: "status = 'pending'"
    add_check_constraint TABLE, "status IN ('pending', 'delivering', 'delivered', 'dead')",
      name: "chk_rpms_outbox_status"
  end
end
