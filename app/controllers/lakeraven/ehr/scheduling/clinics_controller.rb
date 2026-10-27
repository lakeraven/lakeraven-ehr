# frozen_string_literal: true

require "rpms_rpc/api/patient"

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
          @patient_names = @appointments.map { |a| a[:patient_dfn] }.uniq.to_h { |dfn| [ dfn, RpmsRpc::Patient.brief_header(dfn)&.dig(:name) ] }
        end
      end
    end
  end
end
