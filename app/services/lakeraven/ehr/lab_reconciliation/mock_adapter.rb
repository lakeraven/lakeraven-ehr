# frozen_string_literal: true

module Lakeraven
  module EHR
    module LabReconciliation
      class MockAdapter < BaseAdapter
        attr_reader :linkages

        def initialize
          @orders = {}
          @results = {}
          @linkages = []
        end

        def mode
          :mock
        end

        def fetch_pending_orders(patient_dfn)
          (@orders[patient_dfn.to_s] || []).select { |o| o.status == "active" && o.category == "laboratory" }
        end

        def fetch_lab_results(patient_dfn, since: nil)
          results = @results[patient_dfn.to_s] || []
          if since
            cutoff = since.to_datetime
            results.select { |r| r.effective_datetime.nil? || r.effective_datetime >= cutoff }
          else
            results
          end
        end

        def link_result_to_order(order_id:, report_id:)
          @linkages << { order_id: order_id, report_id: report_id }
          true
        end

        def seed_order(order)
          dfn = order.patient_dfn.to_s
          @orders[dfn] ||= []
          @orders[dfn] << order
        end

        def seed_result(report)
          dfn = report.patient_dfn.to_s
          @results[dfn] ||= []
          @results[dfn] << report
        end
      end
    end
  end
end
