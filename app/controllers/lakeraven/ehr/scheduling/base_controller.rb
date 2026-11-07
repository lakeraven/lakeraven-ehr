# frozen_string_literal: true

module Lakeraven
  module EHR
    module Scheduling
      # Scheduling screens (rpms-ux W02). Opening scheduling takes the
      # scheduling.open capability (S-SCH-01.12). Changing appointments on a
      # resource takes the user's modify-appointments right on it (BSDX RESOURCE
      # USER), unless they hold scheduling.supervise (S-SCH-01.13). The screens
      # run on BSDX, which only an IHS backend serves (bprm_scheduling, #647).
      class BaseController < WebController
        include RpmsUnavailableRendering

        before_action :require_bprm_scheduling!
        before_action :require_authentication
        before_action -> { require_capability!("scheduling.open") }
        helper_method :can_book?, :can_overbook?, :can_set_hours?

        private

        def supervisor? = capability?("scheduling.supervise")

        def require_bprm_scheduling!
          return if BackendRegistry.current.provides?(:bprm_scheduling)

          note_audit_denial("browser access refused: backend lacks bprm_scheduling")
          render plain: "Scheduling is not available on this backend.", status: :not_found
        end

        # The resources this user may see: those whose BSDX rights name them, or
        # every one for a supervisor.
        def visible?(resource) = resource[:view] || supervisor?

        # Booking, cancelling and checking in on a resource (S-SCH-01.13): an
        # active resource, and SDZSUP, or the user's modify-appointments right on it
        # in a clinic that does not keep them out (#44 PROHIBIT ACCESS, #729).
        def can_book?(resource)
          return false if resource[:inactive]
          return true if supervisor?

          resource[:modify_appointments] && !kept_out?(resource)
        end

        # Offering an overbook on a full time (S-SCH-01.2): a user who may book
        # there and holds SDZSUP or the overbook right on the resource. Whether
        # this one is allowed (the daily maximum, the master right) is decided
        # when it is booked (AppointmentBookingGateway.book_if_room).
        def can_overbook?(resource)
          can_book?(resource) && (supervisor? || resource[:overbook] == true)
        end

        # Setting a resource's hours (S-SCH-14): an active resource, and SDZSUP or
        # the user's modify-schedule right on it in BSDX RESOURCE USER.
        def can_set_hours?(resource)
          return false if resource[:inactive]

          supervisor? || resource[:modify_schedule] == true
        end

        # Whether the resource's clinic prohibits access and this user is not one
        # of its privileged users. Read once per request per resource.
        def kept_out?(resource)
          (@kept_out ||= {}).fetch(resource[:id]) do
            @kept_out[resource[:id]] = AppointmentBookingGateway.kept_out?(resource, session[:duz])
          end
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
