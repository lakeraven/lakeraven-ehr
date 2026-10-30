# frozen_string_literal: true

module Lakeraven
  module EHR
    module Scheduling
      # Scheduling screens (rpms-ux W02). Opening scheduling takes the
      # scheduling.open capability (S-SCH-01.12). Changing appointments on a
      # resource takes the user's modify-appointments right on it (BSDX RESOURCE
      # USER), unless they hold scheduling.supervise (S-SCH-01.13).
      class BaseController < WebController
        include RpmsUnavailableRendering

        before_action :require_authentication
        before_action -> { require_capability!("scheduling.open") }
        helper_method :can_book?

        private

        def supervisor? = capability?("scheduling.supervise")

        # The resources this user may see: those whose BSDX rights name them, or
        # every one for a supervisor.
        def visible?(resource) = resource[:view] || supervisor?

        def can_book?(resource)
          !resource[:inactive] && (resource[:modify_appointments] || supervisor?)
        end

        def load_resource!
          @resource = AppointmentBookingGateway.resource(params[:resource_id] || params[:id])
          return if @resource && visible?(@resource)

          render plain: "No such clinic resource", status: :not_found
        end

        def parse_date(value)
          Date.iso8601(value.to_s)
        rescue Date::Error
          Date.today
        end
      end
    end
  end
end
