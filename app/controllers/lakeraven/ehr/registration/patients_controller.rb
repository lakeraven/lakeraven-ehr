# frozen_string_literal: true

module Lakeraven
  module EHR
    module Registration
      # The front desk's registration screens (rpms-ux W01, lakeraven-ehr#565):
      # find the patient before registering (S-REG-01), register a new patient
      # (S-REG-02), and the registration record itself.
      #
      # Session-authenticated like the dashboard; every page is audited by
      # WebController's AuditableClinicalAccess under the signed-on DUZ. The
      # pages gate on the RPMS keys BPRM gates on, by name
      # (WebController#require_rpms_key!): seeing a registration takes one of
      # the registration or scheduling keys, adding a patient takes a
      # registration edit key, and the social security number shows only to a
      # holder of AGZVIEWSSN.
      class PatientsController < WebController
        VIEW_KEYS = %w[AGZMGR AGZMENU AGZVIEWONLY SDZSUP SDZMENU].freeze
        REGISTER_KEYS = %w[AGZMGR AGZMENU XUPROG XUPROGMODE].freeze
        SSN_KEY = "AGZVIEWSSN"

        before_action :require_authentication
        before_action :require_view_key!, only: %i[index show]
        before_action :require_register_key!, only: %i[new create]

        def index
          @query = params[:q].to_s.strip
          @dob = params[:dob].presence
          @patients = @query.empty? ? [] : found_patients
          @hrns = @patients.to_h { |p| [ p.dfn, PatientRegistrationGateway.hrn(p.dfn, facility_ien) ] }
          @can_register = can_register?
        end

        def new
          @registration = PatientRegistration.new
          @tribes = PatientRegistrationGateway.tribes
        end

        def create
          @registration = PatientRegistration.new(registration_params)
          return render_possible_matches if possible_matches_block?

          if @registration.register
            flash[:registered] = { "dfn" => @registration.dfn, "hrn" => @registration.hrn,
                                   "name" => @registration.name, "warnings" => @registration.warnings }
            redirect_to registration_patient_path(@registration.dfn)
          else
            @tribes = PatientRegistrationGateway.tribes
            render :new, status: :unprocessable_content
          end
        end

        def show
          @registered = flash[:registered]
          @patient = Patient.find_by_dfn(params[:dfn])
          @hrn = @patient && PatientRegistrationGateway.hrn(@patient.dfn, facility_ien)
          @show_ssn = holds_rpms_key?(SSN_KEY)
          @can_register = can_register?
          return if @patient || @registered

          render plain: "No patient with that record number", status: :not_found
        end

        private

        def require_view_key!
          require_rpms_key!(any_of: VIEW_KEYS, action: "see a registration")
        end

        def require_register_key!
          require_rpms_key!(any_of: REGISTER_KEYS, action: "register a patient")
        end

        def can_register?
          holds_rpms_key?(REGISTER_KEYS)
        end

        # S-REG-02.3: a patient already on file with the same name, date of
        # birth and sex is shown, with their chart numbers, before anything is
        # filed; the clerk can open one instead, or say this is a new patient.
        def possible_matches_block?
          return false if params[:confirmed_new].present? || !@registration.valid?

          @matches = PatientRegistrationGateway.possible_matches(
            name: @registration.name, dob: @registration.dob, sex: @registration.sex
          )
          @matches.any?
        end

        def render_possible_matches
          @hrns = @matches.to_h { |p| [ p.dfn, PatientRegistrationGateway.hrn(p.dfn, facility_ien) ] }
          @tribes = PatientRegistrationGateway.tribes
          render :possible_matches
        end

        # The health record number is per facility: the signed-on user's
        # division (DUZ(2)), read through BEHOSICX SITEINFO. nil when the
        # broker gave no answer, and then no chart number can be shown.
        def facility_ien
          return @facility_ien if defined?(@facility_ien)

          @facility_ien = SiteGateway.current(session[:duz])&.dig(:ien)
        end

        def found_patients
          patients = Patient.search(@query)
          return patients unless @dob

          wanted = Date.parse(@dob)
          patients.select { |p| p.dob == wanted }
        rescue ArgumentError
          patients
        end

        def registration_params
          params.fetch(:patient_registration, {}).permit(:name, :sex, :dob, :ssn, :tribe_ien, :community)
        end
      end
    end
  end
end
