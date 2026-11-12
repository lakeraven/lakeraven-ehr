# frozen_string_literal: true

module Lakeraven
  module EHR
    # A progress note form token that was spent (#1001). The browser session
    # is a cookie the client holds, so the spent state lives here: a token is
    # claimed once, by whichever request gets there first, whatever cookie it
    # came with.
    #
    # The row keeps a SHA-256 hex digest of the token, never the token, under
    # a unique index. The claim is one INSERT ... ON CONFLICT (digest) DO
    # NOTHING: the database decides the winner, and a refused claim raises
    # nothing, so it never aborts the caller's transaction.
    #
    # The claim must outlive the request's audit transaction: a note filed in
    # RPMS stays filed when that transaction rolls back, so its token must
    # stay spent. Inside an open transaction the INSERT runs on a connection
    # of its own and commits at once, the way AuditEvent.create_detached!
    # writes.
    #
    # Retention: rows are small (a digest and a time) and are never read back
    # except through the unique index. Nothing purges them yet.
    class NoteFormClaim < ApplicationRecord
      self.table_name = "lakeraven_ehr_note_form_claims"

      UNIQUE_INDEX = "index_lakeraven_ehr_note_form_claims_on_digest"

      # True for the first claim of a token, false for every later one. A
      # blank or non-String token is false, and nothing is written.
      def self.claim!(token)
        return false unless token.is_a?(String) && token.present?

        row = { digest: digest(token) }
        detached { insert(row, unique_by: UNIQUE_INDEX, returning: [ :id ]).rows.size == 1 }
      end

      def self.digest(token) = OpenSSL::Digest::SHA256.hexdigest(token)

      # Runs the block on a connection no open transaction can roll back.
      # The transactional-test harness pins one connection for every thread,
      # so there the block runs inline (see AuditEvent.create_detached!).
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
    end
  end
end
