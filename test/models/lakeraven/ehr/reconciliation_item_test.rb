# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ReconciliationItemTest < ActiveSupport::TestCase
      setup do
        @session = ReconciliationSession.create!(patient_dfn: "1", clinician_duz: "301")
      end

      test "requires resource_type" do
        ri = ReconciliationItem.new(reconciliation_session: @session, match_status: "new")
        refute ri.valid?
      end

      test "requires match_status" do
        ri = ReconciliationItem.new(reconciliation_session: @session, resource_type: "Condition")
        refute ri.valid?
      end

      test "validates resource_type inclusion" do
        ri = ReconciliationItem.new(reconciliation_session: @session, resource_type: "Invalid", match_status: "new")
        refute ri.valid?
      end

      test "validates match_status inclusion" do
        ri = ReconciliationItem.new(reconciliation_session: @session, resource_type: "Condition", match_status: "invalid")
        refute ri.valid?
      end

      test "accept! sets decision and metadata" do
        ri = @session.reconciliation_items.create!(resource_type: "Condition", match_status: "new")
        ri.accept!("301")

        assert_equal "accepted", ri.decision
        assert_equal "301", ri.decided_by_duz
        refute_nil ri.decided_at
      end

      test "reject! sets decision and metadata" do
        ri = @session.reconciliation_items.create!(resource_type: "Condition", match_status: "new")
        ri.reject!("301")

        assert_equal "rejected", ri.decision
        assert_equal "301", ri.decided_by_duz
      end

      test "new_item? returns true for new match_status" do
        ri = ReconciliationItem.new(match_status: "new")
        assert ri.new_item?
      end

      test "duplicate? returns true for duplicate match_status" do
        ri = ReconciliationItem.new(match_status: "duplicate")
        assert ri.duplicate?
      end

      test "conflict? returns true for conflict match_status" do
        ri = ReconciliationItem.new(match_status: "conflict")
        assert ri.conflict?
      end

      test "decided scope returns accepted and rejected" do
        @session.reconciliation_items.create!(resource_type: "Condition", match_status: "new", decision: "accepted")
        @session.reconciliation_items.create!(resource_type: "Condition", match_status: "new", decision: "rejected")
        @session.reconciliation_items.create!(resource_type: "Condition", match_status: "new", decision: "pending")

        assert_equal 2, ReconciliationItem.decided.count
      end

      test "pending scope returns undecided" do
        @session.reconciliation_items.create!(resource_type: "Condition", match_status: "new", decision: "accepted")
        @session.reconciliation_items.create!(resource_type: "Condition", match_status: "new", decision: "pending")

        assert_equal 1, ReconciliationItem.pending.count
      end
    end
  end
end
