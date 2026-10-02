# frozen_string_literal: true

module Lakeraven
  module EHR
    module Registration
      # Giving a patient who already has a chart elsewhere a health record
      # number at this facility (rpms-ux S-REG-06, lakeraven-ehr#565). BPRM
      # gates this on AGZMENU and refuses the view-only key (its
      # CanRegisterPatient policy).
      class HrnsController < WebController
        before_action :require_authentication
        before_action :require_register_key!
        before_action :load_patient

        def new
          @assignment = HrnAssignment.new
        end

        def create
          @assignment = HrnAssignment.new(assignment_params)
          if @assignment.file(dfn: @patient.dfn, facility_ien: facility_ien)
            flash[:notice] = "Health record number #{@assignment.hrn} filed for #{@patient.name} at this facility."
            redirect_to registration_patient_path(@patient.dfn)
          else
            render :new, status: :unprocessable_content
          end
        end

        private

        def require_register_key!
          require_rpms_key!(any_of: %w[AGZMENU], none_of: %w[AGZVIEWONLY], action: "give a patient a chart number")
        end

        def load_patient
          @patient = Patient.find_by_dfn(params[:patient_dfn])
          return if @patient

          render plain: "No patient with that record number", status: :not_found
        end

        def facility_ien
          @facility_ien ||= SiteGateway.current(session[:duz])&.dig(:ien)
        end

        def assignment_params
          params.fetch(:hrn_assignment, {}).permit(:hrn)
        end

        def fhir_resource_type = "Patient"
      end
    end
  end
end
