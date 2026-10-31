# frozen_string_literal: true

module Lakeraven
  module EHR
    module Gpra
      # The signed-in homepage: the site's GPRA report from its latest run
      # (#780). Reads only what GpraReportJob stored; nothing is computed here.
      # A user without gpra.view lands on the dashboard instead, since this is
      # where sign-in sends everyone.
      class ReportsController < WebController
        helper GpraHelper

        before_action :require_authentication
        before_action :send_to_dashboard_unless_gpra_viewer

        # GET /
        def show
          @latest = GpraRun.latest
          @run = GpraRun.latest_succeeded
          @previous = @run&.previous_succeeded
          @targets = Lakeraven::EHR.configuration.gpra_targets || {}
        end

        private

        def send_to_dashboard_unless_gpra_viewer
          redirect_to dashboard_path unless capability?("gpra.view")
        end
      end
    end
  end
end
