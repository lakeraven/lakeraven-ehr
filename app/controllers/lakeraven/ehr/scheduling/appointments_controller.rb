# frozen_string_literal: true

module Lakeraven
  module EHR
    module Scheduling
      # Booking an appointment (rpms-ux W02 S-SCH-01, lakeraven-ehr#565): the
      # first scheduling screen. Session-authenticated and audited like the
      # registration screens, and gated on the scheduling keys BPRM gates on
      # (SDZSUP or SDZMENU), by name (WebController#require_rpms_key!).
      class AppointmentsController < WebController
        SCHEDULING_KEYS = %w[SDZSUP SDZMENU].freeze

        before_action :require_authentication
        before_action :require_scheduling_key!

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

        def require_scheduling_key!
          require_rpms_key!(any_of: SCHEDULING_KEYS, action: "book an appointment")
        end

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
