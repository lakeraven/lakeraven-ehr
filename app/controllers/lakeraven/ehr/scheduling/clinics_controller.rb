# frozen_string_literal: true

module Lakeraven
  module EHR
    module Scheduling
      # The clinics a scheduler books into, and one clinic's day (S-SCH-01).
      class ClinicsController < BaseController
        before_action :load_resource!, only: %i[show week]

        # GET /scheduling
        def index
          @resources = AppointmentBookingGateway.resources.select { |r| visible?(r) }
        end

        # GET /scheduling/clinics/:id?date=
        def show
          @date = parse_date(params[:date])
          @day, @appointments = AppointmentBookingGateway.day(@resource, @date)
          @booked_id = flash[:booked_id]
          @notice = flash[:notice]
        end

        # GET /scheduling/clinics/:id/week?date= : the week holding date, as a
        # calendar (S-SCH-05), from one read of its blocks and appointments.
        def week
          monday = ClinicWeek.monday_of(parse_date(params[:date]))
          days = AppointmentBookingGateway.days(@resource, monday, monday + 6)
          @week = ClinicWeek.new(monday: monday, days: days, time_scale: @resource[:time_scale])
          @notice = flash[:notice]
        end
      end
    end
  end
end
