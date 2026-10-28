# frozen_string_literal: true

module Lakeraven
  module EHR
    module Scheduling
      # The clinics a scheduler books into, and one clinic's day (S-SCH-01).
      class ClinicsController < BaseController
        before_action :load_resource!, only: :show

        # GET /scheduling
        def index
          @resources = AppointmentBookingGateway.resources.select { |r| r[:view] || held_keys.include?(SUPERVISOR_KEY) }
        end

        # GET /scheduling/clinics/:id?date=
        def show
          @date = parse_date(params[:date])
          @day, @appointments = AppointmentBookingGateway.day(@resource, @date)
          @booked_id = flash[:booked_id]
          @notice = flash[:notice]
        end
      end
    end
  end
end
