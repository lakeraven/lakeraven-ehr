# frozen_string_literal: true

require "rpms_rpc/api/patient"

module Lakeraven
  module EHR
    module Registration
      # The front desk finds a patient before registering one (rpms-ux S-REG-01),
      # and registers a new one (S-REG-02).
      #
      # Gated on the keys BPRM's registration screens gate on: seeing takes one of
      # the registration keys (AGZMENU, AGZMGR, AGZVIEWONLY) or the scheduling menu
      # keys (SDZMENU, SDZSUP); registering takes AGZMENU or AGZMGR.
      class PatientsController < WebController
        VIEW_KEYS = %w[registration_menu registration_manager registration_view_only scheduling_user scheduling_supervisor].freeze
        REGISTER_KEYS = %w[registration_menu registration_manager].freeze
        REVIEW_PURPOSE = :registration_review
        REVIEW_TTL = 15.minutes

        before_action :require_authentication
        before_action :require_registration_view_key!, only: %i[index show]
        before_action :require_registration_key!, only: %i[new create confirm]
        helper_method :can_register?

        # GET /registration/patients?q=&dob=
        def index
          @query = params[:q].to_s.strip
          @dob = parse_dob(params[:dob])
          @searched = @query.present?
          @matches = @searched ? PatientLookupGateway.find(@query, dob: @dob) : []
        rescue RpmsRpc::Client::RpcError, RpmsRpc::Client::ConnectionError => e
          Rails.logger.error("[registration] patient lookup failed: #{e.class}")
          @lookup_failed = true
          @matches = []
          render :index, status: :service_unavailable
        end

        # GET /registration/patients/:dfn
        def show
          @patient = RpmsRpc::Patient.brief_header(params[:dfn].to_i)
          @registered_hrn = flash[:registered_hrn]
          render :not_found, status: :not_found unless @patient
        end

        # GET /registration/patients/new: the form, and the tribe and community
        # the clerk is choosing from (tribe_search, community_search).
        def new
          @registration = PatientRegistration.new(registration_params)
          load_picklists
        end

        # POST /registration/patients
        def create
          @registration = PatientRegistration.new(registration_params)
          return render_form(:unprocessable_content) unless @registration.valid?

          handle(PatientRegistrationGateway.register(@registration))
        end

        # POST /registration/patients/confirm: the clerk has reviewed the possible
        # matches and says this is a different person. The token proves the
        # matches were shown for exactly these details, to this user, recently.
        # The candidate lookup runs again; only when it finds no one the clerk
        # did not review does the registration file with the override.
        def confirm
          @registration = PatientRegistration.new(registration_params)
          reviewed = reviewed_candidates(@registration)
          unless @registration.valid? && reviewed
            flash.now[:alert] = "The review has expired or does not match these details. Check the possible matches again."
            return render_form(:unprocessable_content)
          end

          result = PatientRegistrationGateway.register(@registration)
          if result.possible_matches? && (result.candidate_dfns - reviewed).empty?
            result = PatientRegistrationGateway.register(@registration, allow_duplicate: true)
          end
          handle(result)
        end

        private

        def handle(result)
          if result.registered?
            flash[:registered_hrn] = result.dfn.to_s
            redirect_to registration_patient_path(result.dfn)
          elsif result.possible_matches?
            render_possible_matches(result.candidate_dfns)
          else
            flash.now[:alert] = result.message.presence || "RPMS did not register the patient."
            render_form(result.status == :unavailable ? :service_unavailable : :unprocessable_content)
          end
        end

        def render_possible_matches(dfns)
          @candidates = dfns.filter_map { |dfn| (header = RpmsRpc::Patient.brief_header(dfn)) && header.merge(dfn: dfn) }
          @review_token = review_verifier.generate(
            { "digest" => @registration.digest, "candidates" => dfns.map(&:to_i).sort, "duz" => session[:duz].to_s },
            purpose: REVIEW_PURPOSE, expires_in: REVIEW_TTL
          )
          render :possible_matches, status: :conflict
        end

        # The DFNs the clerk reviewed for exactly these details, or nil.
        def reviewed_candidates(registration)
          review = review_verifier.verified(params[:review_token].to_s, purpose: REVIEW_PURPOSE)
          return nil unless review.is_a?(Hash)
          return nil unless review["digest"] == registration.digest && review["duz"] == session[:duz].to_s

          Array(review["candidates"]).map(&:to_i)
        end

        def review_verifier
          Rails.application.message_verifier("lakeraven-ehr.registration-review")
        end

        def render_form(status)
          load_picklists
          render :new, status: status
        end

        def load_picklists
          @tribes = PatientRegistrationGateway.tribes(params[:tribe_search])
          @communities = PatientRegistrationGateway.communities(params[:community_search])
        end

        def registration_params
          params.fetch(:registration, {}).permit(:name, :sex, :dob, :ssn, :tribe_ien, :community_ien).to_h
        end

        def can_register?
          held = Array(session[:security_keys])
          REGISTER_KEYS.any? { |key| held.include?(key) }
        end

        def require_registration_view_key!
          held = Array(session[:security_keys])
          head :forbidden unless VIEW_KEYS.any? { |key| held.include?(key) }
        end

        def require_registration_key!
          head :forbidden unless can_register?
        end

        def parse_dob(value)
          Date.iso8601(value.to_s) if value.present?
        rescue Date::Error
          nil
        end
      end
    end
  end
end
