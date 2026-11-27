# frozen_string_literal: true

module Lakeraven
  module EHR
    # Part2Label -- the marker a record carries when it holds, or may hold,
    # 42 CFR Part 2 content (#906, slice of #522). One row per
    # (record_type, record_id). Identifiers and a security code only; never
    # clinical text.
    #
    # security_code is deliberately NOT validated against a vocabulary. A
    # row whose code this version does not recognise must still load and be
    # read, because Part2Posture counts ANY label row as Part 2 — an unknown
    # label is never a reason to treat a record as clean.
    #
    # A label outlives the caller's transaction. The chart runs the whole
    # action inside the request's audit transaction (AuditableClinicalAccess),
    # which can roll back after the note was filed in RPMS; the note stays
    # filed, so its label must stay written. Inside an open transaction mark!
    # runs on a connection of its own and commits at once, the way
    # NoteFormClaim.claim! and AuditEvent.create_detached! write.
    class Part2Label < ApplicationRecord
      self.table_name = "lakeraven_ehr_part2_labels"

      PART2_SECURITY_CODE = "42CFRPart2"
      SECURITY_SYSTEM = "http://terminology.hl7.org/CodeSystem/v3-ActCode"

      # record_type for a TIU progress note, keyed by its note IEN.
      TIU_NOTE = "tiu_note"

      validates :patient_dfn, :record_type, :record_id, :security_code, presence: true
      validates :record_id, uniqueness: { scope: :record_type }

      # The ONE normalisation of a record's identifiers, used by both the
      # write (mark!) and the read (Part2Posture.part2?), so a label written
      # for " 70001" or "TIU_NOTE" is found for "70001" / "tiu_note".
      # Only surrounding whitespace is stripped. NUL bytes are kept (unlike
      # String#strip, which also removes edge NULs) so that storable_key?
      # and mark! see them and reject the key.
      def self.normalized_key(record_type:, record_id:)
        { record_type: strip_whitespace(record_type.to_s).downcase, record_id: strip_whitespace(record_id.to_s) }
      end

      # [[:space:]] does not match NUL.
      SURROUNDING_WHITESPACE = /\A[[:space:]]+|[[:space:]]+\z/

      def self.strip_whitespace(value)
        value.gsub(SURROUNDING_WHITESPACE, "")
      end
      private_class_method :strip_whitespace

      # PostgreSQL refuses a NUL byte in a string, so a value carrying one
      # can be neither stored nor looked up.
      NUL = "\u0000"

      # Whether a normalized key can be stored and looked up: every value
      # present and free of NUL bytes. Part2Posture asks this before
      # querying; mark! refuses a key that fails it.
      def self.storable_key?(key)
        key.values.none? { |value| value.blank? || value.include?(NUL) }
      end

      # Labels a record as Part 2. Idempotent: an existing row for the
      # record is left as it is (whatever its code) and counts as success.
      # Blank inputs, or inputs carrying a NUL byte, raise
      # ActiveRecord::RecordInvalid and write nothing.
      #
      # The lookup, the insert and its retries all run detached: inside an
      # open transaction, on a connection of its own that commits at once.
      # So the label survives a rollback of the caller's transaction, and a
      # statement that fails at the database never aborts it. Errors raised
      # there reach the caller unchanged.
      #
      # A concurrent writer may commit the same record between the lookup
      # and the insert. The insert runs in a savepoint, so a unique-index
      # refusal rolls back only the savepoint and never aborts the
      # surrounding transaction; that refusal, or a uniqueness-only
      # validation failure, means the record is already labelled, and the
      # existing row is returned.
      def self.mark!(patient_dfn:, record_type:, record_id:)
        key = normalized_key(record_type: record_type, record_id: record_id)
        attributes = key.merge(patient_dfn: patient_dfn.to_s)
        refuse_nul!(attributes)
        detached { find_by(key) || insert_label!(key, attributes) }
      end

      def self.insert_label!(key, attributes)
        transaction(requires_new: true) do
          create!(attributes.merge(security_code: PART2_SECURITY_CODE))
        end
      rescue ActiveRecord::RecordNotUnique
        find_by!(key)
      rescue ActiveRecord::RecordInvalid => e
        raise unless only_taken?(e.record)

        find_by!(key)
      end
      private_class_method :insert_label!

      # Runs the block on a connection no open transaction can roll back.
      # The transactional-test harness pins one connection for every thread,
      # so there the block runs inline (see AuditEvent.create_detached!).
      #
      # Pool sizing: inside an open transaction the write takes a SECOND
      # pooled connection while the request still holds its own, so the
      # pool must be sized for that: each concurrent request that labels a
      # note may need two connections at once. When no connection frees up
      # within the pool's checkout timeout, mark! raises
      # ActiveRecord::ConnectionTimeoutError; ProgressNoteService then
      # reports :label_failed and ProgressNotesController records "part 2
      # label failed" in the note submission's audit row (Part2Posture still
      # treats the unlabelled suspected note as Part 2 at read time).
      # AuditEvent.create_detached! and NoteFormClaim.claim! use the same
      # pattern and need the same headroom.
      def self.detached(&block)
        conn = connection
        return yield unless conn.transaction_open?
        return yield if conn.respond_to?(:pinned) && conn.pinned

        Thread.new do
          Thread.current.report_on_exception = false
          connection_pool.with_connection(&block)
        end.value
      end
      private_class_method :detached

      # Raises ActiveRecord::RecordInvalid, before any query, when a value
      # carries a NUL byte: the database would refuse it with an
      # ArgumentError rather than a database error.
      def self.refuse_nul!(attributes)
        with_nul = attributes.select { |_name, value| value.include?(NUL) }.keys
        return if with_nul.empty?

        record = new(attributes)
        with_nul.each { |name| record.errors.add(name, :invalid, message: "contains a NUL byte") }
        raise ActiveRecord::RecordInvalid, record
      end
      private_class_method :refuse_nul!

      def self.only_taken?(record)
        record.errors.of_kind?(:record_id, :taken) && record.errors.size == 1
      end
      private_class_method :only_taken?
    end
  end
end
