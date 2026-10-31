# frozen_string_literal: true

require "test_helper"
require File.expand_path("../../db/migrate/20260902020000_create_backend_assertion_jtis", __dir__)

module Lakeraven
  module EHR
    class CreateBackendAssertionJtisMigrationTest < ActiveSupport::TestCase
      TABLE = :lakeraven_ehr_backend_assertion_jtis

      def after_teardown
        super
        BackendAssertionJti.reset_column_information
      end

      test "up is safe when the client_id replay table already exists" do
        BackendAssertionJti.create!(
          client_id: "client-existing", jti: "jti-existing", expires_at: 5.minutes.from_now
        )

        assert_nothing_raised { run_migration(:up) }

        assert BackendAssertionJti.exists?(jti: "jti-existing")
        assert connection.column_exists?(TABLE, :client_id)
      end

      test "up creates the client_id replay table on a fresh database" do
        connection.drop_table(TABLE)

        run_migration(:up)

        assert connection.column_exists?(TABLE, :client_id)
        assert_not connection.column_exists?(TABLE, :issuer)
        assert connection.index_exists?(
          TABLE, [ :client_id, :jti ], unique: true, name: "idx_backend_assertion_jti_uniqueness"
        )
        assert connection.index_exists?(TABLE, :expires_at)
      end

      test "up renames issuer to client_id when 20260923000001 already created the table" do
        install_legacy_replay_table!
        insert_legacy_row!("client-a", "jti-kept")

        run_migration(:up)
        run_migration(:up)

        assert connection.column_exists?(TABLE, :client_id)
        assert_not connection.column_exists?(TABLE, :issuer)
        assert connection.index_exists?(
          TABLE, [ :client_id, :jti ], unique: true, name: "idx_backend_assertion_jti_uniqueness"
        )
        BackendAssertionJti.reset_column_information
        kept = BackendAssertionJti.find_by!(jti: "jti-kept")
        assert_equal "client-a", kept.client_id
      end

      test "down restores issuer on a table adapted from 20260923000001" do
        install_legacy_replay_table!
        insert_legacy_row!("client-a", "jti-kept")
        run_migration(:up)

        run_migration(:down)

        assert connection.column_exists?(TABLE, :issuer)
        assert_not connection.column_exists?(TABLE, :client_id)
        row = connection.select_one(
          "SELECT issuer, jti FROM #{TABLE} WHERE jti = #{connection.quote("jti-kept")}"
        )
        assert_equal "client-a", row["issuer"]
        assert_equal "jti-kept", row["jti"]
      end

      test "down drops a replay table this migration created" do
        connection.drop_table(TABLE)
        run_migration(:up)

        run_migration(:down)

        assert_not connection.table_exists?(TABLE)
      end

      private

      def connection
        ActiveRecord::Base.connection
      end

      def run_migration(direction)
        ActiveRecord::Migration.suppress_messages do
          ::CreateBackendAssertionJtis.new.public_send(direction)
        end
      end

      def install_legacy_replay_table!
        connection.drop_table(TABLE, if_exists: true)
        connection.create_table(TABLE) do |t|
          t.string :issuer, null: false
          t.string :jti, null: false
          t.datetime :expires_at, null: false
          t.timestamps
        end
        connection.add_index TABLE, [ :issuer, :jti ],
          unique: true, name: "index_backend_assertion_jtis_on_issuer_and_jti"
        connection.add_index TABLE, :expires_at, name: "index_backend_assertion_jtis_on_expires_at"
      end

      def insert_legacy_row!(issuer, jti)
        now = Time.current
        connection.execute(<<~SQL)
          INSERT INTO #{TABLE} (issuer, jti, expires_at, created_at, updated_at)
          VALUES (
            #{connection.quote(issuer)},
            #{connection.quote(jti)},
            #{connection.quote(5.minutes.from_now)},
            #{connection.quote(now)},
            #{connection.quote(now)}
          )
        SQL
      end
    end
  end
end
