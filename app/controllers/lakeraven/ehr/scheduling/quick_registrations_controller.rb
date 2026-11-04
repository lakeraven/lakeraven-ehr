# frozen_string_literal: true

require "securerandom"

module Lakeraven
  module EHR
    module Scheduling
      # Registering a caller who has no chart while booking them (rpms-ux
      # S-REG-05): IHS scheduling's mini-registration. The scheduler enters
      # name, sex, date of birth and SSN, and RPMS files the patient with a
      # temporary chart number, or the one the caller was given; then the
      # booking carries on where it was, with the new patient chosen.
      #
      # Gated on patient.quick_register (SDZREGMENU) and the user's booking right
      # on the clinic. The write is AG's own add, AGG ADD NEW PATIENT, through
      # PatientRegistrationGateway; RPMS checks again that the user may run it.
      class QuickRegistrationsController < BaseController
        SUBMISSION_ID = Registration::PatientsController::SUBMISSION_ID

        before_action :require_bprm_registration!
        before_action -> { require_capability!("patient.quick_register") }
        before_action :load_resource!
        before_action :require_booking_right!
        before_action :load_booking_context

        # GET /scheduling/clinics/:resource_id/registrations/new?start=&length=
        def new
          @registration = QuickRegistration.new
          issue_submission
        end

        # POST /scheduling/clinics/:resource_id/registrations. A form is filed
        # at most once: its one-time token is spent before RPMS is asked (#721).
        def create
          @registration = QuickRegistration.new(registration_params)
          return render_form(:unprocessable_content) unless @registration.valid?

          unless params[:submission_id].to_s.match?(SUBMISSION_ID)
            flash.now[:alert] = "Open the registration form again, then register the caller."
            return render_form(:unprocessable_content)
          end
          unless RegistrationReview.use!("submission:#{params[:submission_id]}", duz: session[:duz])
            flash.now[:alert] = "This form was already submitted. Find the patient by name before registering again."
            return render_form(:conflict)
          end

          handle(PatientRegistrationGateway.register(@registration))
        end

        private

        def handle(result)
          if result.registered?
            flash[:quick_registered_hrn] = result.hrn.to_s
            redirect_to booking_path(result.dfn)
          elsif result.hrn_not_filed?
            flash[:alert] = "The patient was registered, but RPMS did not file a chart number. Ask the front desk to assign one when the patient arrives."
            redirect_to booking_path(result.dfn)
          elsif result.outcome_unknown?
            flash.now[:alert] = "RPMS did not confirm the registration. Find the patient by name before registering again."
            render_form(:service_unavailable, new_token: false)
          elsif result.possible_matches?
            @candidates = result.candidate_dfns.filter_map { |dfn| shown_candidate(dfn) }
            render :possible_matches, status: :conflict
          else
            flash.now[:alert] = result.message.presence || "RPMS did not register the caller."
            render_form(:unprocessable_content)
          end
        end

        # The booking form, with this patient chosen, at the time the scheduler
        # was booking.
        def booking_path(dfn)
          scheduling_new_clinic_appointment_path(@resource[:id], start: @start, length: @length, booking: { patient_dfn: dfn })
        end
        helper_method :booking_path

        def shown_candidate(dfn)
          header = RpmsRpc::Patient.brief_header(dfn.to_i)
          header&.merge(dfn: dfn.to_i)
        rescue RpmsRpc::Client::RpcError
          nil
        end

        # Registration runs on AG, which only an IHS backend serves (#647).
        def require_bprm_registration!
          return if BackendRegistry.current.provides?(:bprm_registration)

          note_audit_denial("browser access refused: backend lacks bprm_registration")
          render plain: "Registration is not available on this backend.", status: :not_found
        end

        def require_booking_right!
          return if can_book?(@resource)

          render plain: "You cannot book appointments on #{@resource[:name]}", status: :forbidden
        end

        # Where the booking was: the time and length, carried through the form.
        def load_booking_context
          @start = params[:start].to_s.presence
          @length = params[:length].to_s.presence || @resource[:time_scale]
        end

        def render_form(status, new_token: true)
          issue_submission if new_token
          @submission_id ||= params[:submission_id]
          render :new, status: status
        end

        def issue_submission
          @submission_id = SecureRandom.uuid
        end

        def registration_params
          params.fetch(:registration, {}).permit(:name, :sex, :dob, :ssn, :no_ssn_reason, :chart_number).to_h
        end
      end
    end
  end
end
