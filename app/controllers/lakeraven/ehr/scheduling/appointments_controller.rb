# frozen_string_literal: true

module Lakeraven
  module EHR
    module Scheduling
      # Booking an appointment (rpms-ux W02 S-SCH-01, lakeraven-ehr#565): the
      # first scheduling screen. Session-authenticated and audited like the
      # registration screens; the scheduling keys BPRM gates on (SDZMENU,
      # SDZSUP) are not in rpms-rpc's key registry yet, so signing on is the
      # gate until they are.
      class AppointmentsController < WebController
        before_action :require_authentication

        def new
          @booking = AppointmentBooking.new(minutes: 20)
        end

        # A successful booking renders its confirmation from the broker's
        # reply: there is no confirmed read of a single BSDX appointment to
        # redirect to yet.
        def create
          @booking = AppointmentBooking.new(booking_params)
          if @booking.book
            @patient = Patient.find_by_dfn(@booking.dfn)
            render :create
          else
            render :new, status: :unprocessable_content
          end
        end

        private

        def booking_params
          params.fetch(:appointment_booking, {}).permit(:resource, :dfn, :date, :time, :minutes, :note)
        end

        # The audit concern derives the FHIR type from the controller name;
        # a booking is an Encounter-shaped event about a patient.
        def fhir_resource_type = "Encounter"
      end
    end
  end
end
