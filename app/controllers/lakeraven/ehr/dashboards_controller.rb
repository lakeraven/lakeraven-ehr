# frozen_string_literal: true

module Lakeraven
  module EHR
    class DashboardsController < WebController
      before_action :require_authentication

      def show
        @active_cases_count = 3
        @my_tasks_count = 2
        @pending_referrals_count = 1
      end
    end
  end
end
