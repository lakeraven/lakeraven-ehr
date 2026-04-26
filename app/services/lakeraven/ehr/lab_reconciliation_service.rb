# frozen_string_literal: true

module Lakeraven
  module EHR
    # LabReconciliationService - Match lab results to originating CPOE lab orders.
    # ONC 170.315(a)(2) - CPOE Laboratory
    class LabReconciliationService
      ReconciliationResult = Struct.new(:matched_pairs, :unmatched_results, :unfulfilled_orders, keyword_init: true) do
        def fully_reconciled?
          unmatched_results.empty? && unfulfilled_orders.empty?
        end

        def matched_count
          matched_pairs.size
        end
      end

      def initialize(adapter: nil)
        @adapter = adapter || LabReconciliation::ReconciliationAdapterFactory.build
      end

      def reconcile(patient_dfn:, since: nil)
        orders = @adapter.fetch_pending_orders(patient_dfn)
        results = @adapter.fetch_lab_results(patient_dfn, since: since)

        matched_pairs = []
        claimed_order_ids = Set.new
        claimed_report_ids = Set.new

        code_index = build_index(orders) { |o| o.code if o.code.present? }
        name_index = build_index(orders) { |o| normalize(o.code_display) if o.code_display.present? }

        # Pass 1: Match by LOINC code
        results.each do |report|
          next if report.code.blank?
          match = code_index[report.code]
          next unless match && !claimed_order_ids.include?(match.id)

          matched_pairs << build_match(match, report, :code)
          claimed_order_ids << match.id
          claimed_report_ids << report_id(report)
        end

        # Pass 2: Match by test name
        results.each do |report|
          next if claimed_report_ids.include?(report_id(report))
          next if report.code_display.blank?

          key = normalize(report.code_display)
          match = name_index[key]
          next unless match && !claimed_order_ids.include?(match.id)
          next if match.code.present? && report.code.present? && match.code != report.code

          matched_pairs << build_match(match, report, :name)
          claimed_order_ids << match.id
          claimed_report_ids << report_id(report)
        end

        # Record linkages
        matched_pairs.each do |pair|
          @adapter.link_result_to_order(
            order_id: pair[:order].id,
            report_id: report_id(pair[:report])
          )
        end

        unmatched = results.reject { |r| claimed_report_ids.include?(report_id(r)) }
        unfulfilled = orders.reject { |o| claimed_order_ids.include?(o.id) }

        ReconciliationResult.new(
          matched_pairs: matched_pairs,
          unmatched_results: unmatched,
          unfulfilled_orders: unfulfilled
        )
      end

      def self.result_status(reports)
        return :pending if reports.empty?
        reports.all? { |r| r.status == "final" } ? :final : :partial
      end

      private

      def build_index(orders)
        index = {}
        orders.each do |order|
          key = yield(order)
          index[key] ||= order if key
        end
        index
      end

      def build_match(order, report, match_type)
        { order: order, report: report, match_type: match_type }
      end

      def report_id(report)
        report.respond_to?(:ien) ? report.ien : report.id
      end

      def normalize(text)
        text.to_s.downcase.strip.gsub(/\s+/, " ")
      end
    end
  end
end
