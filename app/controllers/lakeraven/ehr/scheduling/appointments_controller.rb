# frozen_string_literal: true

module Lakeraven
  module EHR
    module Scheduling
      # Booking an appointment on a clinic resource (rpms-ux S-SCH-01).
      #
      # BSDX ADD NEW APPOINTMENT files whatever it is given (a fifth booking into
      # a four-slot block files), so the time is checked here first: it must lie
      # in an open block and have a place left at every step (ClinicDay). The
      # server's own refusals (the patient already booked then, not on file)
      # come back as its message. Overbooking is not offered yet.
      class AppointmentsController < BaseController
        before_action :load_resource!
        before_action :require_booking_right!

        # GET /scheduling/clinics/:resource_id/appointments/new?start=&q=
        def new
          @booking = AppointmentBooking.new(start: params[:start], length: @resource[:time_scale], patient_dfn: params.dig(:booking, :patient_dfn))
          @patients = AppointmentBookingGateway.patients(params[:q])
        end

        # POST /scheduling/clinics/:resource_id/appointments
        def create
          @booking = AppointmentBooking.new(booking_params)
          return render_new(:unprocessable_content) unless @booking.valid?

          day, = AppointmentBookingGateway.day(@resource, @booking.start_time.to_date)
          unless day.room_for?(@booking.start_time, @booking.length)
            flash.now[:alert] = "That time is full or outside the clinic's open hours. Choose another time."
            return render_new(:conflict)
          end

          result = AppointmentBookingGateway.book(@booking, @resource)
          if result.booked?
            flash[:booked_id] = result.appointment_id
            redirect_to scheduling_clinic_path(@resource[:id], date: @booking.start_time.to_date.iso8601)
          elsif result.status == :unknown
            flash.now[:alert] = "RPMS did not confirm the booking. Check the clinic's day before booking again."
            render_new(:service_unavailable)
          else
            flash.now[:alert] = result.message.presence || "RPMS did not book the appointment."
            render_new(:unprocessable_content)
          end
        end

        private

        def require_booking_right!
          return if can_book?(@resource)

          render plain: "You cannot book appointments on #{@resource[:name]}", status: :forbidden
        end

        def render_new(status)
          @patients = AppointmentBookingGateway.patients(params[:q])
          render :new, status: status
        end

        def booking_params
          params.fetch(:booking, {}).permit(:patient_dfn, :start, :length, :note).to_h
        end
      end
    end
  end
end
