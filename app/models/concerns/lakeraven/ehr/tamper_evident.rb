# frozen_string_literal: true

require "openssl"

module Lakeraven
  module EHR
    # Tamper-EVIDENCE for a record that must never change after it is written.
    #
    # Two controls, and they answer different questions:
    #
    #   * `record_digest` DETECTS an edit. A keyed HMAC over what the row says,
    #     computed once at insert. The key lives outside the database, so
    #     someone who can write to the database cannot re-seal a row they
    #     altered. With no key configured the digest is still computed, plain
    #     SHA-256 — that catches corruption and careless edits but NOT a
    #     forgery, and `integrity_mode` says so out loud rather than letting a
    #     reviewer assume otherwise.
    #
    #   * `enforce_append_only!` PREVENTS the edit, at the database, for every
    #     client — psql included. It cannot live in schema.rb, so it is a call
    #     rather than a migration body, and hosts that load the schema instead
    #     of migrating can make it themselves.
    #
    # What is deliberately NOT here: a hash CHAIN linking each row to the one
    # before it. Chaining needs a serialization point at insert, and the only
    # honest one is a lock held for the whole enclosing transaction — which
    # would put every PHI access in the system behind a single audit writer.
    # Deletion and reordering, which a chain is for, are held off at the
    # database instead. See the follow-up issue on periodic sealing.
    module TamperEvident
      extend ActiveSupport::Concern

      included do
        before_create :stamp_record_digest
      end

      class_methods do
        # Fields covered by the digest. Override with an EXPLICIT frozen list —
        # deriving it from `column_names` would mean that adding any column
        # later silently invalidates the digest of every row already written.
        # Anything left out of the list can be edited without detection.
        def digested_attributes
          column_names - %w[id record_digest updated_at]
        end

        # Length-prefixed so no combination of field values can be rearranged
        # into the same payload as a different row.
        def digest_payload(record)
          digested_attributes.sort.map { |name|
            value = canonical_digest_value(record[name])
            "#{name}:#{value.bytesize}:#{value}"
          }.join("|")
        end

        def digest_key
          Lakeraven::EHR.configuration.audit_digest_key.presence
        end

        # Said plainly so a reviewer is never left guessing how much the
        # digest is worth.
        def integrity_mode
          digest_key ? "keyed (HMAC-SHA256)" : "unkeyed (SHA-256) — detects corruption, not forgery"
        end

        def digest_for(record)
          payload = digest_payload(record)
          key = digest_key
          key ? OpenSSL::HMAC.hexdigest("SHA256", key, payload) : OpenSSL::Digest::SHA256.hexdigest(payload)
        end

        # Rows that no longer say what they said when they were written — plus
        # rows carrying no digest at all, which are not "fine", they are
        # unverified. Absence of evidence is never verification.
        def tampered_records
          broken = []
          find_each do |record|
            stored = record.record_digest
            broken << record if stored.blank? || !ActiveSupport::SecurityUtils.secure_compare(stored, digest_for(record))
          end
          broken
        end

        def append_only_enforceable?
          connection.adapter_name.match?(/postg/i)
        end

        # Idempotent: CREATE OR REPLACE for the function, DROP-then-CREATE for
        # the trigger, so running it twice (or after a sibling branch already
        # ran it) is not an error.
        def enforce_append_only!
          return false unless append_only_enforceable?

          quoted = connection.quote_table_name(table_name)
          connection.execute(<<~SQL.squish)
            CREATE OR REPLACE FUNCTION #{append_only_function_name}() RETURNS trigger AS $fn$
            BEGIN
              RAISE EXCEPTION '#{table_name} is append-only; UPDATE is not permitted';
            END;
            $fn$ LANGUAGE plpgsql;
          SQL
          connection.execute("DROP TRIGGER IF EXISTS #{append_only_trigger_name} ON #{quoted};")
          connection.execute(<<~SQL.squish)
            CREATE TRIGGER #{append_only_trigger_name}
              BEFORE UPDATE ON #{quoted}
              FOR EACH ROW EXECUTE FUNCTION #{append_only_function_name}();
          SQL
          true
        end

        # For the migration's `down`, and for the tests that have to make an
        # edit the way an attacker with database access would.
        def relax_append_only!
          return false unless append_only_enforceable?

          connection.execute("DROP TRIGGER IF EXISTS #{append_only_trigger_name} ON #{connection.quote_table_name(table_name)};")
          true
        end

        def append_only_trigger_name
          "#{table_name}_append_only"
        end

        def append_only_function_name
          "#{table_name}_reject_update"
        end

        # Times to a fixed precision and everything else to its string form,
        # so a value that round-trips through the database digests the same.
        def canonical_digest_value(value)
          case value
          when nil then ""
          when Time, DateTime, ActiveSupport::TimeWithZone then value.utc.iso8601(6)
          else value.to_s
          end
        end
      end

      private

      def stamp_record_digest
        # AR's timestamp callback only fills what is still blank, so setting
        # it here keeps the value that gets digested and the value that gets
        # stored identical.
        self.created_at ||= Time.current
        self.record_digest = self.class.digest_for(self)
      end
    end
  end
end
