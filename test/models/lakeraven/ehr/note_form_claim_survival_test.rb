# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # A claim made inside a transaction that then rolls back stays made: the
    # request's audit transaction can roll back after a note was filed in
    # RPMS, and its form must stay spent. Outside the transactional-test
    # harness, the way production runs.
    class NoteFormClaimSurvivalTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      TOKEN = "SYNTHETIC-FORM-TOKEN-survival-0001"

      setup { NoteFormClaim.delete_all }
      teardown { NoteFormClaim.delete_all }

      test "a claim made in a transaction that rolls back is still claimed" do
        claimed = nil
        ActiveRecord::Base.transaction do
          claimed = NoteFormClaim.claim!(TOKEN)
          raise ActiveRecord::Rollback
        end

        assert_equal true, claimed
        assert_equal false, NoteFormClaim.claim!(TOKEN)
        assert_equal 1, NoteFormClaim.count
      end

      test "a refused claim inside a transaction leaves it usable" do
        assert_equal true, NoteFormClaim.claim!(TOKEN)

        ActiveRecord::Base.transaction do
          assert_equal false, NoteFormClaim.claim!(TOKEN)
          assert_equal 1, NoteFormClaim.count
        end
      end

      test "a blank or non-String token is refused without a write" do
        [ nil, "", "  ", 42, [ TOKEN ] ].each do |token|
          assert_equal false, NoteFormClaim.claim!(token), token.inspect
        end
        assert_equal 0, NoteFormClaim.count
      end
    end
  end
end
