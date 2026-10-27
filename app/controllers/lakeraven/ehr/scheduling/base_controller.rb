# frozen_string_literal: true

module Lakeraven
  module EHR
    module Scheduling
      # Scheduling screens (rpms-ux W02). Opening scheduling takes SDZMENU or
      # SDZSUP (S-SCH-01.12). Changing appointments on a resource takes the
      # user's modify-appointments right on it (BSDX RESOURCE USER), unless they
      # hold SDZSUP (S-SCH-01.13).
      class BaseController < WebController
        VIEW_KEYS = %w[scheduling_user scheduling_supervisor].freeze
        SUPERVISOR_KEY = "scheduling_supervisor"

        before_action :require_authentication
        before_action :require_scheduling_key!
        helper_method :can_book?

        private

        def require_scheduling_key!
          head :forbidden unless VIEW_KEYS.any? { |key| held_keys.include?(key) }
        end

        def held_keys = Array(session[:security_keys])

        def can_book?(resource)
          !resource[:inactive] && (resource[:modify_appointments] || held_keys.include?(SUPERVISOR_KEY))
        end

        def load_resource!
          @resource = AppointmentBookingGateway.resource(params[:resource_id] || params[:id])
          return if @resource && (@resource[:view] || held_keys.include?(SUPERVISOR_KEY))

          render plain: "No such clinic resource", status: :not_found
        end

        def parse_date(value)
          Date.iso8601(value.to_s)
        rescue Date::Error
          Date.current
        end
      end
    end
  end
end
