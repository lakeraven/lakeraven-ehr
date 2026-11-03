# frozen_string_literal: true

module Lakeraven
  module EHR
    module LabReconciliation
      # What production runs until a lab source exists. Every call raises, so a
      # missing lab feed is never read as "no pending orders".
      class NotConfiguredAdapter < BaseAdapter
        class NotConfigured < StandardError; end

        def mode
          :not_configured
        end

        def fetch_pending_orders(_patient_dfn)
          not_configured!
        end

        def fetch_lab_results(_patient_dfn, since: nil)
          not_configured!
        end

        def link_result_to_order(order_id:, report_id:)
          not_configured!
        end

        private

        def not_configured!
          raise NotConfigured, "Lab reconciliation is not configured on this server"
        end
      end
    end
  end
end
