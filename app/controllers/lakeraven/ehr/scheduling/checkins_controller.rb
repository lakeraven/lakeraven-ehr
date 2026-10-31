# frozen_string_literal: true

module Lakeraven
  module EHR
    module Scheduling
      # Checking a patient in for an appointment (rpms-ux S-SCH-03).
      #
      # BSDX CHECKIN APPOINTMENT files a second check-in and one with no
      # provider at a clinic that requires one, so the appointment's state, the
      # day and the provider are checked here first.
      class CheckinsController < BaseController
        before_action :load_resource!
        before_action :require_booking_right!
        before_action :load_appointment!

        # GET /scheduling/clinics/:resource_id/appointments/:appointment_id/checkin?date=&provider_search=
        def new
          @checkin = build(at: Time.now.strftime("%Y-%m-%dT%H:%M"))
          @providers = providers
        end

        # POST /scheduling/clinics/:resource_id/appointments/:appointment_id/checkin
        def create
          @checkin = build(**checkin_params.symbolize_keys)
          @providers = providers
          return render(:new, status: :unprocessable_content) unless @checkin.valid?

          result = AppointmentCheckinGateway.check_in(@appointment[:id], at: @checkin.time, provider_ien: @checkin.provider_ien)
          if result.checked_in?
            flash[:notice] = "Checked in #{@appointment[:patient_name]} at #{@checkin.time.strftime('%H:%M')}."
            redirect_to scheduling_clinic_path(@resource[:id], date: @date.iso8601)
          else
            flash.now[:alert] = result.message.presence || "RPMS did not confirm the check-in. Check the clinic's day."
            render :new, status: (result.status == :unknown ? :service_unavailable : :unprocessable_content)
          end
        end

        private

        def build(**attrs)
          checkin = AppointmentCheckin.new(attrs)
          checkin.appointment = @appointment
          checkin.provider_required = AppointmentCheckinGateway.provider_required?(@resource)
          checkin
        end

        # The visit provider is a provider: only holders of the PROVIDER key,
        # as VueCentric's provider selection asks ORWU NEWPERS (#726).
        def providers
          text = params[:provider_search].to_s.strip
          text.empty? ? [] : PractitionerGateway.search(text, key: "PROVIDER").first(15)
        end

        def require_booking_right!
          return if can_book?(@resource)

          render plain: "You cannot change appointments on #{@resource[:name]}", status: :forbidden
        end

        def load_appointment!
          @date = parse_date(params[:date])
          @appointment = AppointmentBookingGateway.appointment(@resource, params[:appointment_id], @date)
          return render(plain: "No such appointment on #{@resource[:name]} that day", status: :not_found) unless @appointment

          why = not_checkable_because(@appointment)
          render(plain: "This appointment #{why}.", status: :conflict) if why
        end

        def not_checkable_because(appointment)
          return "is cancelled" if appointment[:cancelled]
          return "is marked no-show" if appointment[:no_show]
          return "is checked out" if appointment[:checkout_time]

          "is already checked in" if appointment[:checkin_time]
        end

        def checkin_params
          params.fetch(:checkin, {}).permit(:at, :provider_ien).to_h
        end
      end
    end
  end
end
