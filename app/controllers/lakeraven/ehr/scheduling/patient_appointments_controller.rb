# frozen_string_literal: true

module Lakeraven
  module EHR
    module Scheduling
      # One patient's appointments across clinics (rpms-ux S-SCH-05.6), kept to
      # today, the past or the future if asked (S-SCH-05.7). An appointment in a
      # clinic the scheduler can open links to that clinic's day, where it is
      # cancelled or checked in.
      class PatientAppointmentsController < BaseController
        WHEN = %w[today past future].freeze

        # GET /scheduling/patients/:dfn/appointments?when=
        def index
          @dfn = params[:dfn].to_i
          @patient = RpmsRpc::Patient.brief_header(@dfn)
          return render(plain: "No such patient", status: :not_found) unless @patient

          @when = params[:when].presence_in(WHEN)
          @appointments = AppointmentBookingGateway.patient_appointments(@dfn).select { |a| in_when?(a[:start_time]&.to_date) }
          @my_resource_ids = AppointmentBookingGateway.resources.select { |r| visible?(r) }.map { |r| r[:id] }
        end

        private

        def in_when?(date)
          case @when
          when "today" then date == Date.today
          when "past" then date && date < Date.today
          when "future" then date && date > Date.today
          else true
          end
        end
      end
    end
  end
end
