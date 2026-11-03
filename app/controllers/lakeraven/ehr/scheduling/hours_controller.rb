# frozen_string_literal: true

module Lakeraven
  module EHR
    module Scheduling
      # Setting a clinic resource's hours (rpms-ux S-SCH-14): its blocks in BSDX
      # ACCESS BLOCK, by weekday over a range of dates. Scheduling itself takes
      # SDZMENU or SDZSUP (S-SCH-14.6); setting a resource's hours takes SDZSUP,
      # or the user's modify-schedule right on it in BSDX RESOURCE USER, the
      # right Windows Scheduling asks for the same change.
      class HoursController < BaseController
        before_action :load_resource!
        before_action :require_schedule_right!

        # GET /scheduling/clinics/:resource_id/hours/new
        def new
          start = Date.today.next_day
          @hours = ClinicHours.new(weekdays: (1..5).to_a, opens: "08:00", closes: "17:00", slots: 1,
                                   first_date: start.iso8601, last_date: (start >> 1).iso8601)
          @access_types = AppointmentBookingGateway.access_types
        end

        # POST /scheduling/clinics/:resource_id/hours
        def create
          @hours = ClinicHours.new(hours_params)
          @access_types = AppointmentBookingGateway.access_types
          return render(:new, status: :unprocessable_content) unless valid_hours?

          @result = ClinicHoursGateway.set(@hours, @resource)
          case @result.status
          when :set
            flash[:notice] = "Hours set on #{helpers.pluralize(@result.days_set.size, 'day')}."
            redirect_to scheduling_clinic_path(@resource[:id], date: @hours.first.iso8601)
          when :conflict
            render :new, status: :conflict
          when :unknown
            flash.now[:alert] = "RPMS did not confirm the change. Check the clinic's days before setting the hours again."
            render :new, status: :service_unavailable
          else
            flash.now[:alert] = "RPMS refused the hours for #{@result.stopped_on&.strftime('%b %-d, %Y')}. #{@result.message}".strip
            render :new, status: :unprocessable_content
          end
        end

        private

        def require_schedule_right!
          return if can_set_hours?(@resource)

          render plain: "You cannot set the hours of #{@resource[:name]}", status: :forbidden
        end

        # The access type must be one the open-time search offers (S-SCH-14.3):
        # active, and not one that prevents access.
        def valid_hours?
          valid = @hours.valid?
          if @hours.access_type_id && @access_types.none? { |t| t[:id] == @hours.access_type_id }
            @hours.errors.add(:access_type_id, "is not an active access type")
            valid = false
          end
          valid
        end

        def hours_params
          params.fetch(:hours, {}).permit(:opens, :closes, :slots, :access_type_id, :first_date, :last_date, weekdays: []).to_h
        end
      end
    end
  end
end
