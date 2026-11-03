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
        include SchedulingAppointmentChange

        before_action :load_resource!
        before_action :require_booking_right!
        before_action :load_appointment!, except: :undo
        before_action :load_checked_in_appointment!, only: :undo

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

          result = AppointmentCheckinGateway.check_in(
            @appointment[:id], at: @checkin.time, provider_ien: @checkin.provider_ien,
            reread: -> { AppointmentBookingGateway.appointment(@resource, @appointment[:id], @date) }
          )
          if result.checked_in?
            flash[:notice] = "Checked in #{@appointment[:patient_name]} at #{@checkin.time.strftime('%H:%M')}."
            flash[:alert] = "RPMS filed the check-in but reported: #{result.message} Check the visit." if result.message
            redirect_to scheduling_clinic_path(@resource[:id], date: @date.iso8601)
          else
            flash.now[:alert] = result.message.presence || "RPMS did not confirm the check-in. Check the clinic's day."
            render :new, status: (result.status == :unknown ? :service_unavailable : :unprocessable_content)
          end
        end

        # POST /scheduling/clinics/:resource_id/appointments/:appointment_id/checkin/undo
        #
        # S-SCH-03.9, through BSDX CHECKIN APPOINTMENT with "@" as the time. It
        # answers success for an appointment that was never checked in, so only a
        # checked-in one, not yet checked out, gets here. It leaves the visit the
        # check-in made, so the scheduler is told.
        def undo
          result = AppointmentVisitGateway.undo_checkin(@appointment, reread: -> { reread_appointment })
          report(result, done: [ "Undid the check-in of #{patient_at}. The appointment is booked again.",
                                 ("A visit made at check-in stays in RPMS." if creates_visit?) ].compact.join(" "))
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

        def load_appointment!
          @date = parse_date(params[:date])
          @appointment = AppointmentBookingGateway.appointment(@resource, params[:appointment_id], @date)
          return render(plain: "No such appointment on #{@resource[:name]} that day", status: :not_found) unless @appointment

          why = not_checkable_because(@appointment)
          render(plain: "This appointment #{why}.", status: :conflict) if why
        end

        def load_checked_in_appointment!
          @date = parse_date(params[:date])
          @appointment = reread_appointment
          return render(plain: "No such appointment on #{@resource[:name]} that day", status: :not_found) unless @appointment

          refuse_with(not_undoable_because(@appointment))
        end

        def not_undoable_because(appointment)
          return "is cancelled" if appointment[:cancelled]
          return "is checked out; undo the check-out first" if appointment[:checkout_time]

          "is not checked in" unless appointment[:checkin_time]
        end

        def creates_visit?
          setup = Array(::RpmsRpc::Scheduling.clinic_setup).find { |c| c[:location_ien].to_i == @resource[:hospital_location_id].to_i }
          setup&.dig(:create_visit).to_s.upcase == "YES"
        rescue ::RpmsRpc::Error, IOError, SystemCallError
          false
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
