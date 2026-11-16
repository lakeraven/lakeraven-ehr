# frozen_string_literal: true

module Lakeraven
  module EHR
    module Scheduling
      # Read-only site holiday dates and the selected clinic's holiday policy
      # (#616). This does not imply that a holiday is the only booking rule.
      class ClinicHolidaysController < BaseController
        rate_limit only: %i[index]
        before_action :load_resource!
        before_action :require_clinic!
        before_action :load_year!

        def index
          @calendar = ClinicHolidaysGateway.read(@resource, year: @year)
          return if @calendar

          render :unavailable, status: :service_unavailable
        end

        private

        def require_clinic!
          return if @resource[:hospital_location_id].to_i.positive?

          render plain: "This resource is not a clinic in RPMS.", status: :not_found
        end

        def load_year!
          value = params.key?(:year) ? params[:year] : SiteTime.today.year.to_s
          if value.is_a?(String) && value.match?(/\A\d{4}\z/) && (1800..2699).cover?(value.to_i)
            @year = value.to_i
          else
            render plain: "Choose a year from 1800 to 2699.", status: :bad_request
          end
        end
      end
    end
  end
end
