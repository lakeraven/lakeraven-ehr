# frozen_string_literal: true

module Lakeraven
  module EHR
    module Scheduling
      # A clinic's wait list (rpms-ux S-SCH-10): who needs an appointment no
      # slot suits yet, adding and changing an entry, taking one off, and
      # booking from it. Seeing it takes the clinic; changing it takes the
      # right to book there.
      class WaitListsController < BaseController
        WRITES = %i[new create edit update removal remove booking book].freeze

        rate_limit only: %i[index] + WRITES

        before_action :load_resource!
        before_action :load_list!
        before_action :require_booking_right!, only: WRITES
        before_action :require_active_list!, only: %i[new create]
        before_action :load_entry!, only: %i[edit update removal remove booking book]
        before_action :require_open_entry!, only: %i[removal remove booking book]

        # GET /scheduling/clinics/:resource_id/wait_list?open=&from=&to=
        def index
          @open_only = params[:open] != "0"
          @from = parse_optional(params[:from])
          @to = parse_optional(params[:to])
          dates = (@from || Date.new(1800))..(@to || Date.new(9999)) if @from || @to
          @entries = @list ? WaitListGateway.entries(@list, open_only: @open_only, dates: dates) : []
          @notice = flash[:notice]
        end

        # GET /scheduling/clinics/:resource_id/wait_list/new?q=
        def new
          @addition = WaitListAddition.new({ "added_on" => Date.today }.merge(addition_params))
          render_form(:new, :ok)
        end

        # POST /scheduling/clinics/:resource_id/wait_list
        def create
          @addition = WaitListAddition.new(addition_params)
          return render_form(:new, :unprocessable_content) unless @addition.valid?(:add)

          finish(WaitListGateway.add(@list, @addition), "On the wait list.", :new)
        end

        # GET /scheduling/clinics/:resource_id/wait_list/:entry/edit
        def edit
          @addition = params[:wait_list] ? WaitListAddition.new(addition_params) : WaitListAddition.from_entry(@entry)
          render_form(:edit, :ok)
        end

        # POST /scheduling/clinics/:resource_id/wait_list/:entry
        def update
          @addition = WaitListAddition.new(addition_params.except("patient_dfn", "added_on"))
          return render_form(:edit, :unprocessable_content) unless @addition.valid?

          finish(WaitListGateway.update(@list, @entry[:ien], @addition), "Wait list entry saved.", :edit)
        end

        # GET /scheduling/clinics/:resource_id/wait_list/:entry/removal
        def removal
          @removal = WaitListRemoval.new(removed_on: Date.today)
          load_resolutions
        end

        # POST /scheduling/clinics/:resource_id/wait_list/:entry/removal
        def remove
          @removal = WaitListRemoval.new(params.fetch(:removal, {}).permit(:removed_on, :resolution_ien).to_h)
          load_resolutions
          return render(:removal, status: :unprocessable_content) unless @removal.valid?

          finish(WaitListGateway.remove(@list, @entry[:ien], @removal), "Taken off the wait list.", :removal)
        end

        # GET /scheduling/clinics/:resource_id/wait_list/:entry/booking
        def booking
          @booking = AppointmentBooking.new(patient_dfn: @entry[:patient_dfn], length: @resource[:time_scale], start: params[:start])
        end

        # POST /scheduling/clinics/:resource_id/wait_list/:entry/booking: books
        # the patient, then closes the entry as BSDWLE does (S-SCH-10.7).
        def book
          @booking = AppointmentBooking.new(params.fetch(:booking, {}).permit(:start, :length).to_h.merge(patient_dfn: @entry[:patient_dfn]))
          return render(:booking, status: :unprocessable_content) unless @booking.valid?

          result = AppointmentBookingGateway.book_if_room(@booking, @resource)
          return refuse_booking(result) unless result.booked?

          closed = WaitListGateway.close_as_booked(@list, @entry[:ien])
          flash[:booked_id] = result.appointment_id
          flash[:alert] = "Booked, but the wait list entry is still open: #{closed.message.presence || 'RPMS did not confirm it'}." unless closed.saved?
          redirect_to scheduling_clinic_path(@resource[:id], date: @booking.start_time.to_date.iso8601)
        end

        private

        def load_list!
          @list = WaitListGateway.list_for(@resource)
          return if @list || action_name == "index"

          render plain: "#{@resource[:name]} has no wait list", status: :not_found
        end

        def require_booking_right!
          return if can_book?(@resource)

          render plain: "You cannot change the wait list on #{@resource[:name]}", status: :forbidden
        end

        def require_active_list!
          return unless @list[:inactive]

          flash[:alert] = "The wait list for #{@resource[:name]} is inactive."
          redirect_to scheduling_clinic_wait_list_path(@resource[:id])
        end

        def load_entry!
          @entry = WaitListGateway.entry(@list, params[:entry_id])
          render plain: "No such wait list entry", status: :not_found unless @entry
        end

        def require_open_entry!
          return if @entry[:open]

          flash[:alert] = "That entry is closed."
          redirect_to scheduling_clinic_wait_list_path(@resource[:id], open: "0")
        end

        def render_form(template, status)
          @reasons = WaitListGateway.reasons("A")
          @providers = providers
          @patients = template == :new ? AppointmentBookingGateway.patients(params[:q]) : []
          render template, status: status
        end

        def load_resolutions = @resolutions = WaitListGateway.reasons("R")

        # As check-in names a provider: holders of the PROVIDER key (#726).
        def providers
          text = params[:provider_search].to_s.strip
          text.empty? ? [] : PractitionerGateway.search(text, key: "PROVIDER").first(15)
        end

        def finish(result, notice, template)
          return redirect_to(scheduling_clinic_wait_list_path(@resource[:id]), notice: notice) if result.saved?

          flash.now[:alert] = result.unknown? ? "RPMS did not confirm the change. Check the wait list before trying again." : result.message
          status = result.unknown? ? :service_unavailable : :unprocessable_content
          template == :removal ? render(:removal, status: status) : render_form(template, status)
        end

        def refuse_booking(result)
          flash.now[:alert] =
            case result.status
            when :full then "That time is full or outside the clinic's open hours. Choose another time."
            when :unknown then "RPMS did not confirm the booking. Check the clinic's day before booking again."
            else result.message.presence || "RPMS did not book the appointment."
            end
          render :booking, status: (result.status == :unknown ? :service_unavailable : :conflict)
        end

        def addition_params
          params.fetch(:wait_list, {}).permit(:patient_dfn, :added_on, :reason_ien, :priority, :provider_ien, :recall_on).to_h
        end

        def parse_optional(value)
          Date.iso8601(value.to_s)
        rescue Date::Error
          nil
        end
      end
    end
  end
end
