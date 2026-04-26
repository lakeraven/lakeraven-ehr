# frozen_string_literal: true

module Lakeraven
  module EHR
    module LabReconciliation
      class BaseAdapter
        def mode
          raise NotImplementedError
        end

        def fetch_pending_orders(_patient_dfn)
          raise NotImplementedError
        end

        def fetch_lab_results(_patient_dfn, since: nil)
          raise NotImplementedError
        end

        def link_result_to_order(order_id:, report_id:)
          raise NotImplementedError
        end
      end
    end
  end
end
