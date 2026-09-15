# frozen_string_literal: true

# Tamper-evidence for the PHI audit log (#488).
#
# Two controls, deliberately different in kind:
#
#   * `record_digest` — a keyed digest of what the row says, so an edit made
#     underneath ActiveRecord is DETECTED.
#   * an append-only trigger — so on PostgreSQL an edit is PREVENTED outright.
#
# Written to be safe to run twice, and safe to run on a database where a
# sibling branch already added either piece.
class AddAuditEventIntegrity < ActiveRecord::Migration[8.1]
  TABLE = :lakeraven_ehr_audit_events

  def up
    add_column TABLE, :record_digest, :string unless column_exists?(TABLE, :record_digest)
    add_index TABLE, :agent_who_identifier unless index_exists?(TABLE, :agent_who_identifier)
    add_index TABLE, :entity_identifier unless index_exists?(TABLE, :entity_identifier)

    # The trigger cannot live in schema.rb, so hosts that load the schema
    # rather than running migrations do not get it. It is installed through
    # the model so the same call is available to them (and to the test that
    # proves it works).
    Lakeraven::EHR::AuditEvent.enforce_append_only!
  end

  def down
    Lakeraven::EHR::AuditEvent.relax_append_only!
    remove_index TABLE, :entity_identifier if index_exists?(TABLE, :entity_identifier)
    remove_index TABLE, :agent_who_identifier if index_exists?(TABLE, :agent_who_identifier)
    remove_column TABLE, :record_digest if column_exists?(TABLE, :record_digest)
  end
end
