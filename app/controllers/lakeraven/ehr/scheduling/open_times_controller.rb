# frozen_string_literal: true

module Lakeraven
  module EHR
    module Scheduling
      # Searching a clinic for open times over a range of days (rpms-ux S-SCH-04):
      # each day's blocks with a place left for an appointment of the length asked
      # for, kept to the morning or the afternoon, or to one access type, if
      # asked. A day the clinic takes no booking on (a holiday, past its booking
      # limit, inactive) says why. A time opens the booking form at it
      # (S-SCH-04.7), where it is checked again before filing.
      class OpenTimesController < BaseController
        MAX_DAYS = 14
        PARTS = %w[am pm].freeze

        before_action :load_resource!

        # GET /scheduling/clinics/:id/open_times?from=&to=&length=&part=&access_type=
        def index
          @from = parse_date(params[:from])
          @to = [ [ parse_date(params[:to].presence || (@from + 6).iso8601), @from ].max, @from + (MAX_DAYS - 1) ].min
          @length = [ params[:length].to_i, @resource[:time_scale].to_i ].max
          @part = params[:part].presence_in(PARTS)
          @access_types = AppointmentBookingGateway.access_types
          @access_type = @access_types.map { |t| t[:id] }.find { |id| id == params[:access_type].to_i }
          @days = AppointmentBookingGateway.days(@resource, @from, @to)
          @times = @days.transform_values { |day| day.open_times(@length, part: @part, access_type: @access_type) }
        end
      end
    end
  end
end
