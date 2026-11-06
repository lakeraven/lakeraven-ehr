# frozen_string_literal: true

module Lakeraven
  module EHR
    # The appointment a scheduling change acts on: on this resource, that day,
    # by its BSDX APPOINTMENT id, for a user who may change appointments on the
    # resource (S-SCH-01.13). A controller names the state it needs with
    # refuse_unless; BSDX itself does not refuse most changes in the wrong
    # state, so the check here is what keeps them out.
    module SchedulingAppointmentChange
      extend ActiveSupport::Concern

      private

      def require_booking_right!
        return if can_book?(@resource)

        render plain: "You cannot change appointments on #{@resource[:name]}", status: :forbidden
      end

      def load_appointment!
        @date = parse_date(params[:date])
        @appointment = reread_appointment
        render(plain: "No such appointment on #{@resource[:name]} that day", status: :not_found) unless @appointment
      end

      def reread_appointment = AppointmentBookingGateway.appointment(@resource, params[:appointment_id], @date)

      # Renders 409 with why, in words, when the appointment cannot take the change.
      def refuse_with(why)
        render(plain: "This appointment #{why}.", status: :conflict) if why
      end

      def back_to_day = redirect_to(scheduling_clinic_path(@resource[:id], date: @date.iso8601))

      # After a one-click change: the day, with what happened or RPMS's reason.
      def report(result, done:)
        if result.done?
          flash[:notice] = done
          flash[:alert] = "RPMS made the change but reported: #{result.message}" if result.message
        else
          flash[:alert] = result.message.presence || "RPMS did not confirm the change. Check the clinic's day."
        end
        back_to_day
      end

      def patient_at = "#{@appointment[:patient_name]} at #{@appointment[:start_time].strftime('%H:%M')}"
    end
  end
end
