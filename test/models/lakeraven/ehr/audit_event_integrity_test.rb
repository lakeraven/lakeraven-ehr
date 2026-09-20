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

      # Break ONLY the receipt write: `delete_all` goes straight to SQL and
      # keeps working, so the test expresses "the deletion succeeded and its
      # record could not be written" — the exact hole S5 found.
      def with_broken_receipt
        AuditEvent.define_singleton_method(:create!) do |*|
          raise ActiveRecord::StatementInvalid, "audit store unavailable"
        end
        yield
      ensure
        AuditEvent.singleton_class.send(:remove_method, :create!)
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

      # -- what is REPORTED must be what is INSTALLED (S1) --------------------

      # `append_only_enforceable?` is a CAPABILITY probe (is this PostgreSQL);
      # the gate found it reported to the compliance surface as an
      # INSTALLATION fact — while `db:schema:load`, the default path for a
      # fresh database and every test run, never installs the trigger. The
      # two questions get two methods, and every report asks the second.
      test "append_only_installed? reports the catalog fact, not the adapter capability" do
        skip "append-only enforcement needs PostgreSQL" unless AuditEvent.append_only_enforceable?

        AuditEvent.enforce_append_only!
        assert AuditEvent.append_only_installed?

        AuditEvent.relax_append_only!
        assert AuditEvent.append_only_enforceable?,
          "the capability probe changed — this test distinguishes capability from installation"
        refute AuditEvent.append_only_installed?,
          "the trigger is not installed, but the log still claims the database refuses updates"
      ensure
        AuditEvent.enforce_append_only! if AuditEvent.append_only_enforceable?
      end

      # An unkeyed digest is publicly recomputable: whoever can rewrite the
      # row can re-seal it. The gate proved the full chain — row rewritten,
      # digest recomputed, integrity screen clean. So tamper-EVIDENCE is
      # never claimed without a key, loudly, rather than displaying a clean
      # screen over a control that does not exist.
      test "tamper-evidence is not claimed without a digest key" do
        AuditEvent.enforce_append_only! if AuditEvent.append_only_enforceable?

        refute AuditEvent.tamper_evident?,
          "an unkeyed digest was claimed as tamper-evidence — it is publicly recomputable"
        assert_match(/unkeyed/i, AuditEvent.integrity_mode)
      end

      test "tamper-evidence is claimed only with a key AND installed enforcement" do
        skip "append-only enforcement needs PostgreSQL" unless AuditEvent.append_only_enforceable?

        Lakeraven::EHR.configure { |c| c.audit_digest_key = "test-only-#{SecureRandom.hex(8)}" }
        AuditEvent.enforce_append_only!
        assert AuditEvent.tamper_evident?

        AuditEvent.relax_append_only!
        refute AuditEvent.tamper_evident?,
          "tamper-evidence was claimed while the append-only trigger was not installed"
      ensure
        Lakeraven::EHR.reset_configuration!
        AuditEvent.enforce_append_only! if AuditEvent.append_only_enforceable?
      end

      # The gate's attack, run against the control it mandates: an attacker
      # who can write the table rewrites a refusal into a routine success and
      # RE-SEALS the row with a recomputed (unkeyed) digest. With a key
      # configured, the re-seal must still be detected.
      test "a keyed digest defeats re-sealing by an attacker with database access" do
        Lakeraven::EHR.configure { |c| c.audit_digest_key = "test-only-#{SecureRandom.hex(8)}" }
        event = record!(outcome: "4", outcome_desc: "refused: no reviewer key", agent_who_identifier: "301")

        tamper_with_the_database(
          "UPDATE lakeraven_ehr_audit_events SET outcome = '0', outcome_desc = 'routine access', agent_who_identifier = '999' WHERE id = ?",
          event.id
        )
        forged = event.reload
        unkeyed_reseal = OpenSSL::Digest::SHA256.hexdigest(AuditEvent.digest_payload(forged))
        tamper_with_the_database(
          "UPDATE lakeraven_ehr_audit_events SET record_digest = ? WHERE id = ?",
          unkeyed_reseal, event.id
        )

        assert_includes AuditEvent.tampered_events.map(&:id), event.id,
          "a re-sealed row passed keyed verification — the key is not in the digest"
      ensure
        Lakeraven::EHR.reset_configuration!
      end

      # -- the digest input changes only on purpose (S12) ---------------------

      # Adding a column to the digest input re-scopes what "unaltered" means
      # for every row written afterwards, and excluding one leaves it editable
      # without detection. Either is sometimes right — but it is a DECISION.
      # If this test is red, someone changed the digested field list: confirm
      # the change is deliberate, then update BOTH lists in the same commit.
      test "the digested field list changes only as a deliberate decision" do
        assert_equal %w[
          event_type action outcome outcome_desc entity_type entity_identifier
          entity_id agent_who_type agent_who_identifier agent_name
          agent_network_address tenant_identifier facility_identifier created_at
        ], AuditEvent::DIGESTED_ATTRIBUTES,
          "the digest input drifted — see this test's comment before updating it"
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

      # THE PURGE AND ITS RECEIPT ARE ONE ACT (S5). The first version deleted,
      # then recorded, outside any transaction — a failed receipt left a
      # silent hole inside the six-year floor, and integrity over what
      # remained read clean. "A deletion nobody can see is the one thing
      # worse than keeping the records too long" is only true if the deletion
      # cannot outlive a failed receipt.
      test "a purge whose receipt cannot be written deletes nothing" do
        record!

        travel_to 6.years.from_now + 1.day do
          with_broken_receipt do
            assert_raises(ActiveRecord::StatementInvalid) { AuditRetention.purge! }
          end

          assert_equal 1, AuditEvent.where(event_type: "rest").count,
            "rows were deleted with no receipt — the deletion nobody can see"
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
