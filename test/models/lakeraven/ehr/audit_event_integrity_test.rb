# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # An audit log nobody can trust is not an audit log. These are the three
    # questions a compliance officer gets to ask of it: was this row changed
    # after it was written, can it be changed at all, and how long does it
    # stay.
    class AuditEventIntegrityTest < ActiveSupport::TestCase
      setup { AuditEvent.delete_all }

      # An attacker with database access drops the guard first, so the
      # detection tests have to as well — otherwise they would only ever run
      # in a world where the edit was impossible, and would prove nothing
      # about detection. Idempotent, and a no-op off PostgreSQL.
      def tamper_with_the_database(sql, *binds)
        AuditEvent.relax_append_only!
        AuditEvent.connection.update(AuditEvent.sanitize_sql([ sql, *binds ]))
      ensure
        AuditEvent.enforce_append_only!
      end

      def record!(**overrides)
        AuditEvent.create!({
          event_type: "rest", action: "R", outcome: "0",
          entity_type: "Patient", entity_identifier: "1",
          agent_who_type: "Practitioner", agent_who_identifier: "301"
        }.merge(overrides))
      end

      # -- the row carries its own evidence -----------------------------------

      test "a recorded event carries a digest of what it says" do
        event = record!

        assert event.record_digest.present?, "the event was written with no integrity digest"
        assert_equal 64, event.record_digest.length
      end

      test "verification passes on an untouched log" do
        3.times { |i| record!(entity_identifier: i.to_s) }

        assert_empty AuditEvent.tampered_events
      end

      # The row is edited the way tampering actually happens: underneath
      # ActiveRecord, straight through SQL, by someone with database access.
      test "a row altered behind ActiveRecord's back is detected" do
        event = record!(outcome: "4", outcome_desc: "Insufficient scope")
        untouched = record!

        tamper_with_the_database(
          "UPDATE lakeraven_ehr_audit_events SET outcome = ?, outcome_desc = ? WHERE id = ?",
          "0", "fine, nothing to see", event.id
        )

        tampered = AuditEvent.tampered_events
        assert_includes tampered.map(&:id), event.id, "an altered audit row passed verification"
        refute_includes tampered.map(&:id), untouched.id, "an untouched row was reported as altered"
      end

      test "a row whose digest was stripped is detected, not forgiven" do
        event = record!
        tamper_with_the_database("UPDATE lakeraven_ehr_audit_events SET record_digest = NULL WHERE id = ?", event.id)

        assert_includes AuditEvent.tampered_events.map(&:id), event.id,
          "a row with no digest was treated as verified"
      end

      # -- the database refuses the edit too ----------------------------------

      # The digest DETECTS an edit; this PREVENTS it. Installed by migration in
      # a real deployment; installed here because the dummy app loads schema.rb,
      # which cannot carry a trigger — so without this the control would be
      # tested only in a world where it does not exist.
      test "the database refuses to update an audit row" do
        skip "append-only enforcement needs PostgreSQL" unless AuditEvent.append_only_enforceable?
        AuditEvent.enforce_append_only!
        event = record!

        error = assert_raises(ActiveRecord::StatementInvalid) do
          AuditEvent.connection.update(
            AuditEvent.sanitize_sql([ "UPDATE lakeraven_ehr_audit_events SET outcome = '0' WHERE id = ?", event.id ])
          )
        end
        assert_match(/append-only/i, error.message)
      end

      test "installing append-only enforcement twice is not an error" do
        skip "append-only enforcement needs PostgreSQL" unless AuditEvent.append_only_enforceable?

        AuditEvent.enforce_append_only!
        assert AuditEvent.enforce_append_only!, "a second install was refused"
      end

      test "ActiveRecord refuses to update a persisted audit row" do
        event = record!

        assert_raises(ActiveRecord::ReadOnlyRecord) { event.update!(outcome: "8") }
      end

      # -- retention ----------------------------------------------------------

      test "retention is six years unless the host says longer" do
        assert_equal 6.years, Lakeraven::EHR.configuration.audit_retention_period
      end

      test "an event inside the retention window is not purgeable" do
        record!
        travel_to 5.years.from_now do
          assert_equal 0, AuditRetention.purge!, "an event was purged inside its retention window"
          assert_equal 1, AuditEvent.where(event_type: "rest").count
        end
      end

      test "an event past retention is purged, and the purge is itself audited" do
        record!

        travel_to 6.years.from_now + 1.day do
          assert_equal 1, AuditRetention.purge!
          assert_equal 0, AuditEvent.where(event_type: "rest").count

          receipt = AuditEvent.order(:id).last
          assert_equal "D", receipt.action
          assert_equal "AuditEvent", receipt.entity_type
          assert_match(/1/, receipt.outcome_desc.to_s)
        end
      end

      # A shortened retention is a policy violation, not a configuration
      # choice: it would destroy records the rule still requires.
      test "a retention period shorter than policy refuses to purge" do
        record!
        Lakeraven::EHR.configure { |c| c.audit_retention_period = 1.year }

        travel_to 2.years.from_now do
          error = assert_raises(AuditRetention::RetentionPolicyError) { AuditRetention.purge! }
          assert_match(/6 years/i, error.message)
          assert_equal 1, AuditEvent.where(event_type: "rest").count
        end
      ensure
        Lakeraven::EHR.reset_configuration!
      end
    end
  end
end
