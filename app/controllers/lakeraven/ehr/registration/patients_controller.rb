# frozen_string_literal: true

require "rpms_rpc/api/patient"
require "securerandom"

module Lakeraven
  module EHR
    module Registration
      # The front desk finds a patient before registering one (rpms-ux S-REG-01),
      # and registers a new one (S-REG-02).
      #
      # Gated on capabilities (Capabilities, ADR 0010): registration.search,
      # registration.view and patient.register.
      class PatientsController < WebController
        include RpmsUnavailableRendering

        # A form submission token: the UUID the form was issued.
        SUBMISSION_ID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
        REVIEW_PURPOSE = :registration_review
        REVIEW_TTL = 15.minutes

        before_action :require_authentication
        # The search is AG's own lookup (AGG LOOKUP PATIENTS), which RPMS runs for
        # registration users only: a scheduler is refused it, and finds patients
        # with VueCentric's selection when booking instead.
        before_action -> { require_capability!("registration.search") }, only: :index
        before_action -> { require_capability!("registration.view") }, only: :show
        before_action -> { require_capability!("patient.register") }, only: %i[new create confirm]

        # GET /registration/patients: the search form.
        # POST /registration/patients/search (q, dob): the search. Only a POST searches,
        # so a patient's SSN, name or date of birth never travels in a URL (#722).
        def index
          @query = request.post? ? params[:q].to_s.strip : ""
          @dob = request.post? ? parse_dob(params[:dob]) : nil
          @searched = @query.present?
          @matches = @searched ? PatientLookupGateway.find(@query, dob: @dob) : []
        rescue RpmsRpc::Client::RpcError, RpmsRpc::Client::ConnectionError => e
          return end_session_for_closed_rpms! if rpms_connection_closed?

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
          issue_submission
        end

        # POST /registration/patients. A form is filed at most once (#721): its
        # one-time token is spent, under the same unique index as a review,
        # before RPMS is asked, so a double click or a resent form stops here.
        # The form shown again after any answer carries a new token.
        def create
          @registration = PatientRegistration.new(registration_params)
          return render_form(:unprocessable_content) unless @registration.valid?

          submission = params[:submission_id].to_s
          unless submission.match?(SUBMISSION_ID)
            flash.now[:alert] = "Open the registration form again, then register the patient."
            return render_form(:unprocessable_content)
          end
          unless RegistrationReview.use!("submission:#{submission}", duz: session[:duz])
            flash.now[:alert] = "This form was already submitted. Search for the patient before registering again."
            return render_form(:conflict)
          end

          handle(PatientRegistrationGateway.register(@registration))
        end

        # POST /registration/patients/confirm: the clerk has reviewed the possible
        # matches and says this is a different person. The token proves the
        # matches were shown for exactly these details, to this user, recently.
        # The candidate lookup runs again; only when it finds no one the clerk
        # did not review does the registration file with the override.
        def confirm
          @registration = PatientRegistration.new(registration_params)
          review = verified_review(@registration)
          unless @registration.valid? && review
            flash.now[:alert] = "The review has expired or does not match these details. Check the possible matches again."
            return render_form(:unprocessable_content)
          end
          # A review files at most once: a second confirm of it (a double click,
          # a retried request) stops here, before RPMS is asked.
          unless RegistrationReview.use!(review["id"], duz: session[:duz])
            flash.now[:alert] = "This review was already used. Search for the patient before registering again."
            return render_form(:conflict)
          end
          reviewed = Array(review["candidates"]).map(&:to_i)

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
          elsif result.hrn_not_filed?
            flash[:alert] = "The patient was registered, but RPMS did not file a health record number. Ask a registration manager to assign one before the patient is seen."
            redirect_to registration_patient_path(result.dfn)
          elsif result.outcome_unknown?
            render :outcome_unknown, status: :service_unavailable
          elsif result.possible_matches?
            render_possible_matches(result.candidate_dfns)
          else
            flash.now[:alert] = result.message.presence || "RPMS did not register the patient."
            render_form(result.status == :unavailable ? :service_unavailable : :unprocessable_content)
          end
        end

        def render_possible_matches(dfns)
          @candidates = dfns.map { |dfn| shown_candidate(dfn) }
          # Only what the clerk can see may be reviewed. A candidate RPMS will not
          # describe (no name or date of birth) cannot be told apart from this
          # patient, so there is no override: the clerk searches instead.
          @unshowable = @candidates.any?(&:nil?)
          @candidates = @candidates.compact
          unless @unshowable
            @review_token = review_verifier.generate(
              { "id" => SecureRandom.uuid, "digest" => @registration.digest,
                "candidates" => @candidates.map { |c| c[:dfn] }.sort, "duz" => session[:duz].to_s },
              purpose: REVIEW_PURPOSE, expires_in: REVIEW_TTL
            )
          end
          render :possible_matches, status: :conflict
        end

        def shown_candidate(dfn)
          header = RpmsRpc::Patient.brief_header(dfn)
          return nil unless header && header[:name].present? && header[:dob].present?

          header.merge(dfn: dfn.to_i)
        rescue RpmsRpc::Client::RpcError
          nil
        end

        # The review the clerk gave for exactly these details, as this user, or nil.
        def verified_review(registration)
          review = review_verifier.verified(params[:review_token].to_s, purpose: REVIEW_PURPOSE)
          return nil unless review.is_a?(Hash) && review["id"].present?
          return nil unless review["digest"] == registration.digest && review["duz"] == session[:duz].to_s

          review
        end

        def review_verifier
          Rails.application.message_verifier("lakeraven-ehr.registration-review")
        end

        def render_form(status)
          load_picklists
          issue_submission
          render :new, status: status
        end

        def issue_submission
          @submission_id = SecureRandom.uuid
        end

        def load_picklists
          @tribes = PatientRegistrationGateway.tribes(params[:tribe_search])
          @communities = PatientRegistrationGateway.communities(params[:community_search])
        end

        def registration_params
          params.fetch(:registration, {}).permit(:name, :sex, :dob, :ssn, :no_ssn_reason, :tribe_ien, :community_ien).to_h
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
