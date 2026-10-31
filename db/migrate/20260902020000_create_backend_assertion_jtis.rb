# frozen_string_literal: true

# Shared replay-guard state for SMART Backend Services client assertions.
# The unique (client_id, jti) index is the atomic test-and-set: the first
# INSERT wins, every other process/worker/restart sees RecordNotUnique.
#
# 20260923000001 (already shipped) created this same table with an `issuer`
# column. This file is numbered earlier, so an install that already ran the
# later migration still sees this one as pending and would otherwise
# create_table a table that exists. Fresh databases get the client_id
# schema; databases that already have the issuer table are renamed onto it.
class CreateBackendAssertionJtis < ActiveRecord::Migration[8.1]
  TABLE = :lakeraven_ehr_backend_assertion_jtis
  UNIQUE_INDEX = "idx_backend_assertion_jti_uniqueness"
  LEGACY_UNIQUE_INDEX = "index_backend_assertion_jtis_on_issuer_and_jti"

  def up
    if table_exists?(TABLE)
      align_existing_replay_table!
    else
      create_replay_table!
    end
  end

  # A table this migration created has no updated_at. A table adapted from
  # 20260923000001 still has updated_at from t.timestamps; rolling back
  # restores `issuer` so the already-recorded later migration is not left
  # pointing at a dropped table.
  def down
    return unless table_exists?(TABLE)

    if column_exists?(TABLE, :updated_at) && column_exists?(TABLE, :client_id)
      restore_legacy_issuer_column!
    else
      drop_table TABLE
    end
  end

  private

  def create_replay_table!
    create_table TABLE do |t|
      t.string :client_id, null: false
      t.string :jti, null: false
      t.datetime :expires_at, null: false
      t.datetime :created_at, null: false
    end
    add_index TABLE, %i[client_id jti], unique: true, name: UNIQUE_INDEX
    add_index TABLE, :expires_at
  end

  def align_existing_replay_table!
    if column_exists?(TABLE, :issuer) && !column_exists?(TABLE, :client_id)
      rename_column TABLE, :issuer, :client_id
    end

    unless column_exists?(TABLE, :client_id)
      raise ActiveRecord::IrreversibleMigration,
        "#{TABLE} exists without client_id or issuer; refusing to guess the replay key"
    end

    ensure_unique_client_index!
    ensure_expires_at_index!
  end

  def ensure_unique_client_index!
    if index_exists?(TABLE, name: LEGACY_UNIQUE_INDEX)
      rename_index TABLE, LEGACY_UNIQUE_INDEX, UNIQUE_INDEX unless index_exists?(TABLE, name: UNIQUE_INDEX)
    elsif !index_exists?(TABLE, [ :client_id, :jti ], unique: true, name: UNIQUE_INDEX)
      add_index TABLE, %i[client_id jti], unique: true, name: UNIQUE_INDEX
    end
  end

  def ensure_expires_at_index!
    return if index_exists?(TABLE, :expires_at)

    add_index TABLE, :expires_at
  end

  def restore_legacy_issuer_column!
    if index_exists?(TABLE, name: UNIQUE_INDEX) && !index_exists?(TABLE, name: LEGACY_UNIQUE_INDEX)
      rename_index TABLE, UNIQUE_INDEX, LEGACY_UNIQUE_INDEX
    end
    return if column_exists?(TABLE, :issuer) || !column_exists?(TABLE, :client_id)

    rename_column TABLE, :client_id, :issuer
  end
end
