# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class LabReconciliationServiceTest < ActiveSupport::TestCase
      setup do
        @adapter = LabReconciliation::MockAdapter.new
        @service = LabReconciliationService.new(adapter: @adapter)
      end

      # =========================================================================
      # MATCHING BY LOINC CODE
      # =========================================================================

      test "matches result to order by LOINC code" do
        order = build_signed_order(code: "58410-2", code_display: "Complete Blood Count")
        report = build_report(code: "58410-2", code_display: "CBC")
        @adapter.seed_order(order)
        @adapter.seed_result(report)

        result = @service.reconcile(patient_dfn: "12345")

        assert_equal 1, result.matched_count
        assert_equal order, result.matched_pairs.first[:order]
        assert_equal report, result.matched_pairs.first[:report]
        assert_equal :code, result.matched_pairs.first[:match_type]
        assert_empty result.unmatched_results
        assert_empty result.unfulfilled_orders
      end

      test "matches multiple orders to results by code" do
        order1 = build_signed_order(code: "58410-2", code_display: "CBC")
        order2 = build_signed_order(code: "2951-2", code_display: "Sodium")
        report1 = build_report(code: "58410-2", code_display: "CBC")
        report2 = build_report(code: "2951-2", code_display: "Sodium")

        @adapter.seed_order(order1)
        @adapter.seed_order(order2)
        @adapter.seed_result(report1)
        @adapter.seed_result(report2)

        result = @service.reconcile(patient_dfn: "12345")

        assert_equal 2, result.matched_count
        assert result.fully_reconciled?
      end

      # =========================================================================
      # MATCHING BY TEST NAME (FALLBACK)
      # =========================================================================

      test "matches result to order by test name when no code match" do
        order = build_signed_order(code: nil, code_display: "Complete Blood Count")
        report = build_report(code: nil, code_display: "Complete Blood Count")
        @adapter.seed_order(order)
        @adapter.seed_result(report)

        result = @service.reconcile(patient_dfn: "12345")

        assert_equal 1, result.matched_count
        assert_equal :name, result.matched_pairs.first[:match_type]
      end

      test "name matching is case-insensitive" do
        order = build_signed_order(code: nil, code_display: "Complete Blood Count")
        report = build_report(code: nil, code_display: "complete blood count")
        @adapter.seed_order(order)
        @adapter.seed_result(report)

        result = @service.reconcile(patient_dfn: "12345")

        assert_equal 1, result.matched_count
      end

      test "code match takes priority over name match" do
        order = build_signed_order(code: "58410-2", code_display: "CBC")
        report = build_report(code: "58410-2", code_display: "Different Name")
        @adapter.seed_order(order)
        @adapter.seed_result(report)

        result = @service.reconcile(patient_dfn: "12345")

        assert_equal 1, result.matched_count
        assert_equal :code, result.matched_pairs.first[:match_type]
      end

      test "name match rejects when both sides have different codes" do
        order = build_signed_order(code: "58410-2", code_display: "CBC")
        report = build_report(code: "2951-2", code_display: "CBC")
        @adapter.seed_order(order)
        @adapter.seed_result(report)

        result = @service.reconcile(patient_dfn: "12345")

        assert_equal 0, result.matched_count
        assert_equal 1, result.unmatched_results.size
        assert_equal 1, result.unfulfilled_orders.size
      end

      # =========================================================================
      # UNMATCHED RESULTS
      # =========================================================================

      test "result without matching order is unmatched" do
        report = build_report(code: "58410-2", code_display: "CBC")
        @adapter.seed_result(report)

        result = @service.reconcile(patient_dfn: "12345")

        assert_equal 0, result.matched_count
        assert_equal 1, result.unmatched_results.size
        assert_equal report, result.unmatched_results.first
      end

      test "result with different code than any order is unmatched" do
        order = build_signed_order(code: "58410-2", code_display: "CBC")
        report = build_report(code: "2951-2", code_display: "Sodium")
        @adapter.seed_order(order)
        @adapter.seed_result(report)

        result = @service.reconcile(patient_dfn: "12345")

        assert_equal 0, result.matched_count
        assert_equal 1, result.unmatched_results.size
        assert_equal 1, result.unfulfilled_orders.size
      end

      # =========================================================================
      # UNFULFILLED ORDERS
      # =========================================================================

      test "order without matching result is unfulfilled" do
        order = build_signed_order(code: "58410-2", code_display: "CBC")
        @adapter.seed_order(order)

        result = @service.reconcile(patient_dfn: "12345")

        assert_equal 0, result.matched_count
        assert_equal 1, result.unfulfilled_orders.size
        assert_equal order, result.unfulfilled_orders.first
      end

      test "multiple unfulfilled orders are tracked" do
        @adapter.seed_order(build_signed_order(code: "58410-2", code_display: "CBC"))
        @adapter.seed_order(build_signed_order(code: "2951-2", code_display: "Sodium"))

        result = @service.reconcile(patient_dfn: "12345")

        assert_equal 2, result.unfulfilled_orders.size
      end

      # =========================================================================
      # RESULT STATUS LIFECYCLE
      # =========================================================================

      test "result_status returns pending when no reports" do
        assert_equal :pending, LabReconciliationService.result_status([])
      end

      test "result_status returns final when all reports are final" do
        reports = [
          build_report(code: "58410-2", status: "final"),
          build_report(code: "58410-2", status: "final")
        ]
        assert_equal :final, LabReconciliationService.result_status(reports)
      end

      test "result_status returns partial when some reports are not final" do
        reports = [
          build_report(code: "58410-2", status: "final"),
          build_report(code: "58410-2", status: "preliminary")
        ]
        assert_equal :partial, LabReconciliationService.result_status(reports)
      end

      # =========================================================================
      # LINKAGE RECORDING
      # =========================================================================

      test "reconciliation records linkages via adapter" do
        order = build_signed_order(code: "58410-2", code_display: "CBC")
        report = build_report(code: "58410-2", code_display: "CBC")
        @adapter.seed_order(order)
        @adapter.seed_result(report)

        @service.reconcile(patient_dfn: "12345")

        assert_equal 1, @adapter.linkages.size
        assert_equal order.id, @adapter.linkages.first[:order_id]
        assert_equal report.ien, @adapter.linkages.first[:report_id]
      end

      test "no linkage recorded for unmatched results" do
        report = build_report(code: "58410-2", code_display: "CBC")
        @adapter.seed_result(report)

        @service.reconcile(patient_dfn: "12345")

        assert_empty @adapter.linkages
      end

      # =========================================================================
      # SINCE DATE FILTER
      # =========================================================================

      test "since filters out older results" do
        old_report = build_report(code: "58410-2", code_display: "CBC",
                                  effective_datetime: 10.days.ago)
        new_report = build_report(code: "2951-2", code_display: "Sodium",
                                  effective_datetime: 1.day.ago)
        @adapter.seed_result(old_report)
        @adapter.seed_result(new_report)

        result = @service.reconcile(patient_dfn: "12345", since: 5.days.ago)

        assert_equal 1, result.unmatched_results.size
        assert_equal new_report, result.unmatched_results.first
      end

      test "since as Date filters correctly" do
        old_report = build_report(code: "58410-2", code_display: "CBC",
                                  effective_datetime: 10.days.ago)
        @adapter.seed_result(old_report)

        result = @service.reconcile(patient_dfn: "12345", since: 5.days.ago.to_date)

        assert_empty result.unmatched_results
      end

      # =========================================================================
      # FULLY RECONCILED PREDICATE
      # =========================================================================

      test "fully_reconciled? returns true when all matched" do
        order = build_signed_order(code: "58410-2", code_display: "CBC")
        report = build_report(code: "58410-2", code_display: "CBC")
        @adapter.seed_order(order)
        @adapter.seed_result(report)

        result = @service.reconcile(patient_dfn: "12345")

        assert result.fully_reconciled?
      end

      test "fully_reconciled? returns false with unmatched results" do
        report = build_report(code: "58410-2", code_display: "CBC")
        @adapter.seed_result(report)

        result = @service.reconcile(patient_dfn: "12345")

        assert_not result.fully_reconciled?
      end

      test "fully_reconciled? returns true with no orders and no results" do
        result = @service.reconcile(patient_dfn: "12345")

        assert result.fully_reconciled?
      end

      # =========================================================================
      # EDGE CASES
      # =========================================================================

      test "order with blank code only matches by name" do
        order = build_signed_order(code: "", code_display: "CBC")
        report = build_report(code: "", code_display: "CBC")
        @adapter.seed_order(order)
        @adapter.seed_result(report)

        result = @service.reconcile(patient_dfn: "12345")

        assert_equal 1, result.matched_count
        assert_equal :name, result.matched_pairs.first[:match_type]
      end

      test "each order matches at most one result" do
        order = build_signed_order(code: "58410-2", code_display: "CBC")
        report1 = build_report(code: "58410-2", code_display: "CBC", ien: "lab-1")
        report2 = build_report(code: "58410-2", code_display: "CBC", ien: "lab-2")
        @adapter.seed_order(order)
        @adapter.seed_result(report1)
        @adapter.seed_result(report2)

        result = @service.reconcile(patient_dfn: "12345")

        assert_equal 1, result.matched_count
        assert_equal 1, result.unmatched_results.size
      end

      test "each result matches at most one order" do
        order1 = build_signed_order(code: "58410-2", code_display: "CBC")
        order2 = build_signed_order(code: "58410-2", code_display: "CBC")
        report = build_report(code: "58410-2", code_display: "CBC")
        @adapter.seed_order(order1)
        @adapter.seed_order(order2)
        @adapter.seed_result(report)

        result = @service.reconcile(patient_dfn: "12345")

        assert_equal 1, result.matched_count
        assert_equal 1, result.unfulfilled_orders.size
      end

      # =========================================================================
      # ADAPTER FACTORY
      # =========================================================================

      test "factory builds mock adapter in test" do
        adapter = LabReconciliation::ReconciliationAdapterFactory.build(:mock)
        assert_equal :mock, adapter.mode
      end

      private

      def build_signed_order(code:, code_display:)
        order = CpoeOrder.new(
          id: "cpoe-#{SecureRandom.hex(8)}",
          patient_dfn: "12345",
          requester_duz: "789",
          status: "draft",
          intent: "plan",
          category: "laboratory",
          priority: "routine",
          code: code.presence,
          code_display: code_display,
          clinical_reason: "Annual screening",
          authored_on: Time.current
        )
        order.sign!(provider_duz: "789")
        order
      end

      def build_report(code:, code_display: "Lab Test", status: "final", ien: nil, effective_datetime: nil)
        DiagnosticReport.new(
          ien: ien || "lab-#{SecureRandom.hex(4)}",
          patient_dfn: "12345",
          category: DiagnosticReport::CATEGORY_LAB,
          code: code.presence,
          code_display: code_display,
          status: status,
          effective_datetime: effective_datetime || Time.current,
          issued: Time.current
        )
      end
    end
  end
end
