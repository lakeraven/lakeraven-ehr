# frozen_string_literal: true

module Lakeraven
  module EHR
    module Scheduling
      # Cancelling a booked appointment with a reason (rpms-ux S-SCH-02,
      # lakeraven-ehr#565). The appointment is named by its BSDX APPOINTMENT
      # IEN: no confirmed read lists a patient's appointments with that IEN
      # yet, so the number comes from the booking confirmation.
      class CancellationsController < WebController
        before_action :require_authentication
        before_action :require_scheduling_key!

        def new
          @cancellation = AppointmentCancellation.new(appointment_ien: params[:appointment_id])
          @reasons = AppointmentBookingGateway.cancellation_reasons
        end

        def create
          @cancellation = AppointmentCancellation.new(cancellation_params.merge(appointment_ien: params[:appointment_id]))
          if @cancellation.cancel
            render :create
          else
            @reasons = AppointmentBookingGateway.cancellation_reasons
            render :new, status: :unprocessable_content
          end
        end

        private

        def require_scheduling_key!
          require_rpms_key!(any_of: AppointmentsController::SCHEDULING_KEYS, action: "cancel an appointment")
        end

        def cancellation_params
          params.fetch(:appointment_cancellation, {}).permit(:cancelled_by, :reason_ien, :remarks)
        end

        def fhir_resource_type = "Encounter"
      end
    end
  end
end
