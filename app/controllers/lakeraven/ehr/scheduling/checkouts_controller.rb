# frozen_string_literal: true

module Lakeraven
  module EHR
    module Scheduling
      # Checking a patient out (rpms-ux S-SCH-07.1 to 07.4) and undoing it
      # (S-SCH-07.6), through BSDX CHECKOUT APPOINTMENT and BSDX CANCEL
      # CHECKOUT APPT. Both refuse an appointment in the wrong state themselves;
      # the state is still checked here so the clerk is told in words first.
      class CheckoutsController < BaseController
        include SchedulingAppointmentChange

        before_action :load_resource!
        before_action :require_booking_right!
        before_action :load_appointment!
        before_action -> { refuse_with(not_checkable_out_because(@appointment)) }, only: %i[new create]
        before_action -> { refuse_with(@appointment[:checkout_time] ? nil : "is not checked out") }, only: :undo

        # GET /scheduling/clinics/:resource_id/appointments/:appointment_id/checkout?date=
        def new
          @checkout = build(at: Time.now.strftime("%Y-%m-%dT%H:%M"))
        end

        # POST /scheduling/clinics/:resource_id/appointments/:appointment_id/checkout
        def create
          @checkout = build(**params.fetch(:checkout, {}).permit(:at).to_h.symbolize_keys)
          return render(:new, status: :unprocessable_content) unless @checkout.valid?

          result = AppointmentVisitGateway.check_out(@appointment, at: @checkout.time, reread: -> { reread_appointment })
          if result.done?
            flash[:notice] = "Checked out #{@appointment[:patient_name]} at #{@checkout.time.strftime('%H:%M')}."
            flash[:alert] = "RPMS filed the check-out but reported: #{result.message}" if result.message
            back_to_day
          else
            flash.now[:alert] = result.message.presence || "RPMS did not confirm the check-out. Check the clinic's day."
            render :new, status: (result.status == :unknown ? :service_unavailable : :unprocessable_content)
          end
        end

        # POST /scheduling/clinics/:resource_id/appointments/:appointment_id/checkout/undo
        def undo
          result = AppointmentVisitGateway.undo_checkout(@appointment, reread: -> { reread_appointment })
          report(result, done: "Undid the check-out of #{patient_at}. The patient is checked in again.")
        end

        private

        def build(**attrs)
          AppointmentCheckout.new(attrs).tap { |c| c.appointment = @appointment }
        end

        def not_checkable_out_because(appointment)
          return "is cancelled" if appointment[:cancelled]
          return "is already checked out" if appointment[:checkout_time]

          "is not checked in" unless appointment[:checkin_time]
        end
      end
    end
  end
end
