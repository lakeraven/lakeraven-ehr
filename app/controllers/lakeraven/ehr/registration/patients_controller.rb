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
      # RPMS keys BPRM gates registration on (AGZMENU, and AGZVIEWONLY for a
      # read-only clerk) are not in rpms-rpc's key registry yet, so a session
      # cannot carry them; until it can, signing on is the gate.
      class PatientsController < WebController
        before_action :require_authentication

        def index
          @query = params[:q].to_s.strip
          @dob = params[:dob].presence
          @patients = @query.empty? ? [] : found_patients
          @hrns = @patients.to_h { |p| [ p.dfn, PatientRegistrationGateway.hrn(p.dfn, facility_ien) ] }
        end

        def new
          @registration = PatientRegistration.new
          @tribes = PatientRegistrationGateway.tribes
        end

        def create
          @registration = PatientRegistration.new(registration_params)
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
          return if @patient || @registered

          render plain: "No patient with that record number", status: :not_found
        end

        private

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
