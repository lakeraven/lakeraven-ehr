# frozen_string_literal: true

module Lakeraven
  module EHR
    module Scheduling
      # The site-wide holidays (rpms-ux S-SCH-19): listed, added and removed by
      # a scheduling supervisor (SDZSUP). HOLIDAY (#40.5) has a row per date and
      # applies to every clinic; open times drop a holiday's slots (S-SCH-19.9).
      class HolidaysController < BaseController
        rate_limit only: %i[index create remove]

        before_action :require_supervisor!

        # GET /scheduling/holidays
        def index
          @form = HolidayForm.new
          @notice = flash[:notice]
          render_index
        end

        # POST /scheduling/holidays
        def create
          @form = HolidayForm.new(form_params)
          return render_index(:unprocessable_content) unless @form.valid?

          result = SchedulingTablesGateway.add_holiday(@form.calendar_date, @form.name)
          if result.saved?
            flash[:notice] = "Holiday #{@form.name} added on #{@form.calendar_date.iso8601}."
            redirect_to scheduling_holidays_path
          elsif result.status == :unknown
            unconfirmed
          else
            flash.now[:alert] = "RPMS did not add the holiday.#{" #{result.message}" if result.message.present?}"
            render_index(:unprocessable_content)
          end
        end

        # POST /scheduling/holidays/:date/remove
        def remove
          date = strict_date(params[:date])
          return render(plain: "No such date", status: :not_found) unless date

          result = SchedulingTablesGateway.remove_holiday(date)
          case result.status
          when :saved
            flash[:notice] = "Holiday on #{date.iso8601} removed."
            redirect_to scheduling_holidays_path
          when :not_found
            flash[:alert] = "RPMS has no holiday on #{date.iso8601}."
            redirect_to scheduling_holidays_path
          when :refused
            flash[:alert] = "RPMS did not remove the holiday.#{" #{result.message}" if result.message.present?}"
            redirect_to scheduling_holidays_path
          else
            @form = HolidayForm.new
            unconfirmed
          end
        end

        private

        def unconfirmed
          @form ||= HolidayForm.new
          flash.now[:alert] = "RPMS did not confirm the change. Check the holidays before trying again."
          render_index(:service_unavailable)
        end

        # Lists the holidays; a read that fails is shown as a failure, never as
        # an empty list.
        def render_index(status = :ok)
          begin
            @holidays = SchedulingTablesGateway.holidays
          rescue ::RpmsRpc::Error, IOError, SystemCallError => e
            Rails.logger.error("[scheduling] holidays read raised #{e.class}")
            @holidays = nil
            flash.now[:alert] = [ flash.now[:alert].presence, "RPMS did not return the holidays. Try again shortly." ].compact.join(" ")
            status = :service_unavailable
          end
          render :index, status: status
        end

        def strict_date(text)
          Date.iso8601(text.to_s)
        rescue Date::Error
          nil
        end

        def require_supervisor!
          return if supervisor?

          render plain: "Changing holidays takes the scheduling supervisor key (SDZSUP)", status: :forbidden
        end

        def form_params
          params.fetch(:holiday, {}).permit(:date, :name).to_h.symbolize_keys
        end
      end
    end
  end
end
