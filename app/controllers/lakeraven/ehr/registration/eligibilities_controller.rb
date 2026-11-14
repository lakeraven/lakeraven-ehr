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
        rate_limit only: %i[edit update]

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

        # A field the site does not ask for (#981) keeps what RPMS holds: the
        # form does not show it, so nothing the clerk sends changes it.
        def eligibility_params
          permitted = params.fetch(:eligibility, {}).permit(*PatientEligibility::UPDATE_NAMES.keys).to_h
          hidden = []
          hidden += %w[blood_quantum tribe_quantum] unless registration_settings.ask?(:blood_quantum)
          hidden << "enrollment_number" unless registration_settings.ask?(:enrollment_number)
          return permitted if hidden.empty?

          current = PatientEligibility.from_enrollment(enrollment)
          permitted.except(*hidden).merge(hidden.to_h { |field| [ field, current.public_send(field) ] })
        end
      end
    end
  end
end
