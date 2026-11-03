# frozen_string_literal: true

module Lakeraven
  module EHR
    module Scheduling
      # Marking that a patient did not come, and taking it back (rpms-ux
      # S-SCH-08.1, 08.2, 08.4), through BSDX NOSHOW. BSDX NOSHOW refuses
      # nothing: on a built image it marks an appointment not yet due, one
      # checked in, and one already a no-show. So only a booked appointment
      # whose time has passed is offered and accepted here.
      class NoShowsController < BaseController
        include SchedulingAppointmentChange

        before_action :load_resource!
        before_action :require_booking_right!
        before_action :load_appointment!
        before_action -> { refuse_with(not_a_no_show_because(@appointment)) }, only: :create
        before_action -> { refuse_with(@appointment[:no_show] ? nil : "is not marked no-show") }, only: :undo

        # POST /scheduling/clinics/:resource_id/appointments/:appointment_id/no_show
        def create
          result = AppointmentVisitGateway.no_show(@appointment, reread: -> { reread_appointment })
          report(result, done: "Marked #{patient_at} a no-show.")
        end

        # POST /scheduling/clinics/:resource_id/appointments/:appointment_id/no_show/undo
        def undo
          result = AppointmentVisitGateway.undo_no_show(@appointment, reread: -> { reread_appointment })
          report(result, done: "Undid the no-show of #{patient_at}. The appointment is booked again.")
        end

        private

        def not_a_no_show_because(appointment)
          return "is cancelled" if appointment[:cancelled]
          return "is already marked no-show" if appointment[:no_show]
          return "is checked in" if appointment[:checkin_time]

          "is not due yet; mark a no-show once its time has passed" if appointment[:start_time] > Time.now
        end
      end
    end
  end
end
