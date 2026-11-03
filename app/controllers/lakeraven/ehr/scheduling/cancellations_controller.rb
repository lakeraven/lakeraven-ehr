# frozen_string_literal: true

module Lakeraven
  module EHR
    module Scheduling
      # Cancelling an appointment (rpms-ux S-SCH-02), on the patient's or the
      # clinic's behalf, with a reason of the matching type and optional remarks.
      #
      # BSDX CANCEL APPOINTMENT refuses only a checked-in appointment; it files a
      # second cancellation of a cancelled one and a reason of the wrong type.
      # So the appointment's state and the reason's type are checked here first.
      class CancellationsController < BaseController
        before_action :load_resource!
        before_action :require_booking_right!
        before_action :load_appointment!

        # GET /scheduling/clinics/:resource_id/appointments/:appointment_id/cancel?date=&whom=
        def new
          @cancellation = AppointmentCancellation.new(whom: params[:whom].presence || "PC")
          @reasons = AppointmentCancellationGateway.reasons(@cancellation.whom)
        end

        # POST /scheduling/clinics/:resource_id/appointments/:appointment_id/cancel
        def create
          @cancellation = AppointmentCancellation.new(cancellation_params)
          @reasons = AppointmentCancellationGateway.reasons(@cancellation.whom)
          return render(:new, status: :unprocessable_content) unless @cancellation.valid?

          unless @reasons.any? { |r| r[:ien] == @cancellation.reason_ien }
            @cancellation.errors.add(:reason_ien, "is not one that can be filed when #{AppointmentCancellation::WHOM[@cancellation.whom]} cancels")
            return render(:new, status: :unprocessable_content)
          end

          result = AppointmentCancellationGateway.cancel(@appointment[:id], whom: @cancellation.whom,
                                                         reason_ien: @cancellation.reason_ien, remarks: @cancellation.remarks)
          if result.cancelled?
            flash[:notice] = "Cancelled #{@appointment[:patient_name]}'s appointment at #{@appointment[:start_time].strftime('%H:%M')}."
            redirect_to scheduling_clinic_path(@resource[:id], date: @date.iso8601)
          else
            flash.now[:alert] = result.message.presence || "RPMS did not confirm the cancellation. Check the clinic's day."
            render :new, status: (result.status == :unknown ? :service_unavailable : :unprocessable_content)
          end
        end

        private

        def require_booking_right!
          return if can_book?(@resource)

          render plain: "You cannot change appointments on #{@resource[:name]}", status: :forbidden
        end

        # The appointment, on this resource that day, and still cancellable.
        def load_appointment!
          @date = parse_date(params[:date])
          @appointment = AppointmentBookingGateway.appointment(@resource, params[:appointment_id], @date)
          return render(plain: "No such appointment on #{@resource[:name]} that day", status: :not_found) unless @appointment

          why = not_cancellable_because(@appointment)
          render(plain: "This appointment #{why}.", status: :conflict) if why
        end

        def not_cancellable_because(appointment)
          return "is already cancelled" if appointment[:cancelled]
          return "is marked no-show" if appointment[:no_show]

          "is checked in; undo the check-in first" if appointment[:checkin_time]
        end

        def cancellation_params
          params.fetch(:cancellation, {}).permit(:whom, :reason_ien, :remarks).to_h
        end
      end
    end
  end
end
