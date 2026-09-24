# frozen_string_literal: true

# Replay protection for RFC 7523 client assertions. A jti may be presented
# once; the unique index is the claim, so two concurrent presentations cannot
# both succeed. Deliberately a table rather than a cache: a security control
# that disables itself when optional infrastructure is absent is a control that
# fails open. See #496.
class CreateBackendAssertionJtis < ActiveRecord::Migration[8.1]
  def change
    create_table :lakeraven_ehr_backend_assertion_jtis do |t|
      t.string :issuer, null: false
      t.string :jti, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end

    add_index :lakeraven_ehr_backend_assertion_jtis, %i[issuer jti],
              unique: true, name: "index_backend_assertion_jtis_on_issuer_and_jti"
    add_index :lakeraven_ehr_backend_assertion_jtis, :expires_at,
              name: "index_backend_assertion_jtis_on_expires_at"
  end
end
