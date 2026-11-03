# frozen_string_literal: true

module Lakeraven
  module EHR
    module Scheduling
      # Correcting an appointment without rebooking it (rpms-ux S-SCH-09): a
      # booked appointment's note, and its length at a clinic that allows
      # variable lengths; a cancelled or no-show appointment's remarks.
      class AppointmentDetailsController < BaseController
        before_action :load_resource!
        before_action :require_booking_right!
        before_action :load_appointment!

        # GET /scheduling/clinics/:resource_id/appointments/:appointment_id/details?date=
        def new
          @details = build(note: @appointment[:note].to_s.squish, length: length_of(@appointment))
        end

        # POST /scheduling/clinics/:resource_id/appointments/:appointment_id/details
        def create
          @details = build(**details_params.symbolize_keys)
          return render(:new, status: :unprocessable_content) unless @details.valid?

          result = save
          if result.saved?
            flash[:notice] = "Saved #{@appointment[:patient_name]}'s appointment at #{@appointment[:start_time].strftime('%H:%M')}."
            redirect_to scheduling_clinic_path(@resource[:id], date: @date.iso8601)
          else
            flash.now[:alert] = result.message.presence || "RPMS did not confirm the change. Check the clinic's day before saving again."
            render :new, status: { unknown: :service_unavailable, partial: :conflict }.fetch(result.status, :unprocessable_content)
          end
        end

        private

        def save
          if @details.kind == :closed
            AppointmentDetailsGateway.update_remarks(@appointment, remarks: @details.remarks)
          else
            length = @variable && @details.length != length_of(@appointment) ? @details.length : nil
            AppointmentDetailsGateway.update_booked(@appointment, @resource, note: @details.note, length: length)
          end
        end

        def build(**attrs)
          attrs.delete(:length) unless @variable
          details = AppointmentDetails.new(attrs)
          details.kind = @kind
          details.length ||= length_of(@appointment)
          details
        end

        def length_of(appointment) = ((appointment[:end_time] - appointment[:start_time]) / 60).round

        def require_booking_right!
          return if can_book?(@resource)

          render plain: "You cannot change appointments on #{@resource[:name]}", status: :forbidden
        end

        # The appointment, on this resource that day: booked (note and length)
        # or cancelled or no-show (remarks). A checked-in one is not changed here.
        def load_appointment!
          @date = parse_date(params[:date])
          @appointment = AppointmentBookingGateway.appointment(@resource, params[:appointment_id], @date)
          return render(plain: "No such appointment on #{@resource[:name]} that day", status: :not_found) unless @appointment

          @kind = @appointment[:cancelled] || @appointment[:no_show] ? :closed : :booked
          return render(plain: "This appointment is checked in, so its details are not changed here.", status: :conflict) if @kind == :booked && (@appointment[:checkin_time] || @appointment[:checkout_time])

          @variable = @kind == :booked && AppointmentDetailsGateway.variable_length?(@resource)
        end

        def details_params
          params.fetch(:details, {}).permit(:note, :length, :remarks).to_h
        end
      end
    end
  end
end
