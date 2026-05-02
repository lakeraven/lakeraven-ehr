# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ReconciliationSessionTest < ActiveSupport::TestCase
      test "requires patient_dfn" do
        rs = ReconciliationSession.new(clinician_duz: "301")
        refute rs.valid?
        assert rs.errors[:patient_dfn].any?
      end

      test "requires clinician_duz" do
        rs = ReconciliationSession.new(patient_dfn: "1")
        refute rs.valid?
        assert rs.errors[:clinician_duz].any?
      end

      test "defaults status to pending" do
        rs = ReconciliationSession.new(patient_dfn: "1", clinician_duz: "301")
        assert_equal "pending", rs.status
      end

      test "validates status inclusion" do
        rs = ReconciliationSession.new(patient_dfn: "1", clinician_duz: "301", status: "invalid")
        refute rs.valid?
      end

      test "accepts valid statuses" do
        %w[pending in_progress completed cancelled].each do |s|
          rs = ReconciliationSession.new(patient_dfn: "1", clinician_duz: "301", status: s)
          assert rs.valid?, "Expected #{s} to be valid"
        end
      end

      test "has many reconciliation items" do
        rs = ReconciliationSession.create!(patient_dfn: "1", clinician_duz: "301")
        rs.reconciliation_items.create!(resource_type: "Condition", match_status: "new")
        assert_equal 1, rs.reconciliation_items.count
      end

      test "destroys items when session is destroyed" do
        rs = ReconciliationSession.create!(patient_dfn: "1", clinician_duz: "301")
        rs.reconciliation_items.create!(resource_type: "Condition", match_status: "new")

        assert_difference("ReconciliationItem.count", -1) { rs.destroy }
      end

      test "active scope returns pending and in_progress" do
        ReconciliationSession.create!(patient_dfn: "1", clinician_duz: "301", status: "pending")
        ReconciliationSession.create!(patient_dfn: "1", clinician_duz: "301", status: "in_progress")
        ReconciliationSession.create!(patient_dfn: "1", clinician_duz: "301", status: "completed")

        assert_equal 2, ReconciliationSession.active.count
      end

      test "for_patient scope filters by patient_dfn" do
        ReconciliationSession.create!(patient_dfn: "1", clinician_duz: "301")
        ReconciliationSession.create!(patient_dfn: "2", clinician_duz: "301")

        assert_equal 1, ReconciliationSession.for_patient("1").count
      end

      test "progress returns counts" do
        rs = ReconciliationSession.create!(patient_dfn: "1", clinician_duz: "301")
        rs.reconciliation_items.create!(resource_type: "Condition", match_status: "new", decision: "accepted")
        rs.reconciliation_items.create!(resource_type: "MedicationRequest", match_status: "new", decision: "pending")

        p = rs.progress
        assert_equal 2, p[:total]
        assert_equal 1, p[:decided]
        assert_equal 1, p[:pending]
      end

      test "complete! sets status and completed_at" do
        rs = ReconciliationSession.create!(patient_dfn: "1", clinician_duz: "301")
        rs.reconciliation_items.create!(resource_type: "Condition", match_status: "new", decision: "accepted")

        rs.complete!
        assert_equal "completed", rs.status
        refute_nil rs.completed_at
      end

      test "complete! fails when items are undecided" do
        rs = ReconciliationSession.create!(patient_dfn: "1", clinician_duz: "301")
        rs.reconciliation_items.create!(resource_type: "Condition", match_status: "new", decision: "pending")

        refute rs.complete!
        assert_equal "pending", rs.status
      end
    end
  end
end
