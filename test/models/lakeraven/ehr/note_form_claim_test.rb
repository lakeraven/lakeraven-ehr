# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # The server-side record that a progress note form token was spent
    # (#1001, review round 2). The browser session is a cookie the client
    # holds, so a token struck from the session comes back with an older
    # cookie. A claim is a database row: a token value is claimed once, by
    # whichever request gets there first, whatever cookie it came with.
    #
    # The model answers NoteFormClaim.claim!(token) (or .claim(token)): true
    # for the first claim of a token value, false for every later one. The
    # table keeps a digest of the token under a unique index, never the token.
    module NoteFormClaimSpec
      TABLE = "lakeraven_ehr_note_form_claims"
      SYNTHETIC_TOKEN = "SYNTHETIC-FORM-TOKEN-r2-0001"
      OTHER_SYNTHETIC_TOKEN = "SYNTHETIC-FORM-TOKEN-r2-0002"

      def claim_model = Lakeraven::EHR::NoteFormClaim

      def claim(token)
        claimer = claim_model.respond_to?(:claim!) ? :claim! : :claim
        claim_model.public_send(claimer, token)
      end

      # The unique indexes of the claims table, as the database reports them.
      def unique_indexes
        claim_model.connection.indexes(TABLE).select(&:unique)
      end
    end

    class NoteFormClaimTest < ActiveSupport::TestCase
      include NoteFormClaimSpec

      test "the claims are kept in lakeraven_ehr_note_form_claims" do
        assert_equal TABLE, claim_model.table_name
        assert claim_model.connection.table_exists?(TABLE), "the table exists"
      end

      test "the model answers claim! or claim on the class" do
        assert claim_model.respond_to?(:claim!) || claim_model.respond_to?(:claim),
               "NoteFormClaim.claim!(token) or NoteFormClaim.claim(token)"
      end

      test "the first claim of a token answers true and records one row" do
        assert_difference -> { claim_model.count }, 1 do
          assert_equal true, claim(SYNTHETIC_TOKEN)
        end
      end

      test "every later claim of the same token answers false and records nothing" do
        assert_equal true, claim(SYNTHETIC_TOKEN)

        assert_no_difference -> { claim_model.count } do
          assert_equal false, claim(SYNTHETIC_TOKEN)
          assert_equal false, claim(SYNTHETIC_TOKEN)
        end
      end

      test "a refused claim leaves the connection usable inside the caller's transaction" do
        assert_equal true, claim(SYNTHETIC_TOKEN)
        assert_equal false, claim(SYNTHETIC_TOKEN)

        assert_equal 1, claim_model.count, "the next statement still runs"
        assert_equal true, claim(OTHER_SYNTHETIC_TOKEN)
      end

      test "two different tokens are each claimed once" do
        assert_equal true, claim(SYNTHETIC_TOKEN)
        assert_equal true, claim(OTHER_SYNTHETIC_TOKEN)
        assert_equal false, claim(SYNTHETIC_TOKEN)
        assert_equal false, claim(OTHER_SYNTHETIC_TOKEN)
        assert_equal 2, claim_model.count
      end

      test "the raw token is not stored: no column holds it" do
        assert_equal true, claim(SYNTHETIC_TOKEN)

        row = claim_model.order(:id).last
        assert row, "the claim is a row"
        row.attributes.each do |column, value|
          refute_equal SYNTHETIC_TOKEN, value, "column #{column} holds the raw token"
          refute_includes value.to_s, SYNTHETIC_TOKEN, "column #{column} carries the raw token"
        end
      end

      test "the same token always stores the same digest, and another token a different one" do
        assert_equal true, claim(SYNTHETIC_TOKEN)
        assert_equal true, claim(OTHER_SYNTHETIC_TOKEN)

        digest_column = unique_indexes.map(&:columns).find { |columns| Array(columns).size == 1 }
        assert digest_column, "a unique index on the one digest column"
        digests = claim_model.order(:id).pluck(Array(digest_column).first)
        assert_equal 2, digests.uniq.size
        assert digests.all? { |digest| digest.to_s.length >= 32 }, "a digest, not a short code: #{digests.map { |d| d.to_s.length }}"
      end

      test "a unique index on the digest column refuses a second row for the same token" do
        index = unique_indexes.find { |candidate| Array(candidate.columns).size == 1 }
        assert index, "a unique index on one column of #{TABLE}"
        refute_equal [ claim_model.primary_key ], Array(index.columns), "the digest column, not the primary key"

        assert_equal true, claim(SYNTHETIC_TOKEN)
        copy = claim_model.order(:id).last.dup

        assert_raises(ActiveRecord::RecordNotUnique) do
          claim_model.transaction(requires_new: true) { copy.save!(validate: false) }
        end
        assert_equal 1, claim_model.count
      end
    end

    # Two requests claiming one token at the same moment: each on a database
    # connection of its own, so the test cannot run inside one transaction.
    class NoteFormClaimConcurrencyTest < ActiveSupport::TestCase
      include NoteFormClaimSpec

      self.use_transactional_tests = false

      CLAIMANTS = 4

      setup { claim_model.delete_all }
      teardown { "Lakeraven::EHR::NoteFormClaim".safe_constantize&.delete_all }

      test "of several claims of one token made at once, exactly one succeeds" do
        ready = Queue.new
        go = Queue.new
        threads = Array.new(CLAIMANTS) do
          Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do
              ready << true
              go.pop
              claim(SYNTHETIC_TOKEN)
            end
          end
        end
        CLAIMANTS.times { ready.pop }
        CLAIMANTS.times { go << true }
        answers = threads.map(&:value)

        assert_equal [ true ], answers.select { |answer| answer == true }, "one claim wins: #{answers.inspect}"
        assert_equal CLAIMANTS - 1, answers.count(false), "the others are refused, not raised: #{answers.inspect}"
        assert_equal 1, claim_model.count
      end
    end
  end
end
