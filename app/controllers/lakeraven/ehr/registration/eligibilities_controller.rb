# frozen_string_literal: true

require "rpms_rpc/api/tribal"

module Lakeraven
  module EHR
    module Registration
      # The front desk records a patient's tribe, blood quantum and eligibility
      # (rpms-ux S-REG-07.1) through AG's Eligibility window
      # (RpmsRpc::Patient.update), and reads them back with
      # RpmsRpc::Tribal.enrollment.
      class EligibilitiesController < PatientEditsController
        # GET /registration/patients/:dfn/eligibility/edit
        def edit
          @eligibility = PatientEligibility.from_enrollment(enrollment)
          render_form(:ok)
        end

        # PATCH /registration/patients/:dfn/eligibility. Find tribe posts the
        # form back here with tribe_search and no save.
        def update
          @eligibility = PatientEligibility.new(eligibility_params)
          return render_form(:ok) if params[:tribe_search].present? && params[:commit].blank?
          return render_form(:unprocessable_content) unless @eligibility.valid?

          save(@eligibility, PatientEligibility.from_enrollment(enrollment), "Tribe and eligibility saved.")
        end

        private

        def enrollment = RpmsRpc::Tribal.enrollment(dfn) || {}

        def render_form(status)
          @classifications = PatientRecordGateway.classifications
          @tribes = PatientRegistrationGateway.tribes(params[:tribe_search])
          @current_tribe = enrollment.slice(:tribe_ien, :tribe_name) if @tribes.empty?
          render :edit, status: status
        end

        def eligibility_params
          params.fetch(:eligibility, {}).permit(*PatientEligibility::UPDATE_NAMES.keys).to_h
        end
      end
    end
  end
end
