# frozen_string_literal: true

module Lakeraven
  module EHR
    module Scheduling
      # A walk-in (rpms-ux S-SCH-06): a registered patient at the window with no
      # appointment is booked at the clinic's current slot and checked in, in one
      # step. Everything the check-in needs is checked before anything is filed
      # (S-SCH-06.3); AppointmentWalkInGateway books and checks in.
      #
      # The patient and provider searches post (find), so a name typed to find
      # a patient never lands in a URL or a log line (#722).
      class WalkInsController < BaseController
        rate_limit only: %i[new find create]

        before_action :load_resource!
        before_action :require_booking_right!

        # GET /scheduling/clinics/:resource_id/walk_ins/new
        def new
          @walk_in = build(at: Time.now.strftime("%Y-%m-%dT%H:%M"))
          load_lists
        end

        # POST /scheduling/clinics/:resource_id/walk_ins/find : the searches,
        # with what the clerk entered kept and nothing filed.
        def find
          @walk_in = build(**walk_in_params.symbolize_keys)
          load_lists
          render :new
        end

        # POST /scheduling/clinics/:resource_id/walk_ins
        def create
          @walk_in = build(**walk_in_params.symbolize_keys)
          load_lists
          return render(:new, status: :unprocessable_content) unless @walk_in.valid?

          result = AppointmentWalkInGateway.book_and_check_in(@walk_in, @resource, provider_ien: @walk_in.provider_ien, stop_ien: @walk_in.stop_ien,
                                                                                  overbook: { duz: session[:duz].to_i, supervisor: supervisor?, confirmed: params[:overbook] == "1" })
          if result.status == :overbook_offered
            @offer_overbook = true
            return render(:new, status: :conflict)
          end

          if result.checked_in?
            flash[:notice] = "Walk-in booked and checked in at #{@walk_in.time.strftime('%H:%M')}."
            flash[:alert] = result.message if result.message
            flash[:booked_id] = result.appointment_id
            redirect_to scheduling_clinic_path(@resource[:id], date: Date.today.iso8601)
          else
            flash.now[:alert] = alert_for(result)
            render :new, status: status_for(result)
          end
        end

        private

        def build(**attrs)
          walk_in = AppointmentWalkIn.new(attrs)
          walk_in.provider_required = AppointmentCheckinGateway.provider_required?(@resource)
          walk_in.stop_required = AppointmentWalkInGateway.several_stops?(@resource)
          walk_in
        end

        def load_lists
          @patients = AppointmentBookingGateway.patients(params[:q])
          text = params[:provider_search].to_s.strip
          @providers = text.empty? ? [] : PractitionerGateway.search(text, key: "PROVIDER").first(15)
          @stops = @walk_in.stop_required ? AppointmentWalkInGateway.stops : []
        end

        def alert_for(result)
          case result.status
          when :full then "The clinic has no place at this time, or is not open now. The walk-in was not booked."
          when :unknown then "RPMS did not confirm the walk-in. Check the clinic's day before trying again."
          else result.message.presence || "RPMS did not book the walk-in."
          end
        end

        def status_for(result)
          { full: :conflict, unknown: :service_unavailable, booked_only: :conflict }.fetch(result.status, :unprocessable_content)
        end

        def require_booking_right!
          return if can_book?(@resource)

          render plain: "You cannot book appointments on #{@resource[:name]}", status: :forbidden
        end

        def walk_in_params
          params.fetch(:walk_in, {}).permit(:patient_dfn, :at, :provider_ien, :stop_ien).to_h
        end
      end
    end
  end
end
