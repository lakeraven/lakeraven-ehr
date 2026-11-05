# frozen_string_literal: true

module Lakeraven
  module EHR
    module Registration
      # The front desk keeps a patient's demographics current (rpms-ux S-REG-20)
      # through AG's Personal Detail window (RpmsRpc::Patient.update).
      class DemographicsController < PatientEditsController
        rate_limit only: %i[edit update]

        # GET /registration/patients/:dfn/demographics/edit
        def edit
          @demographics = PatientDemographics.from_record(@record)
          render_form(:ok)
        end

        # PATCH /registration/patients/:dfn/demographics
        def update
          @demographics = PatientDemographics.new(demographics_params)
          return render_form(:unprocessable_content) unless @demographics.valid?

          save(@demographics, PatientDemographics.from_record(@record), "Demographics saved.")
        end

        private

        def render_form(status)
          @marital_statuses = PatientRecordGateway.choices(:marital_status)
          @religions = PatientRecordGateway.choices(:religion)
          @states = PatientRecordGateway.choices(:state)
          @employers = PatientRecordGateway.choices(:employer)
          render :edit, status: status
        end

        def demographics_params
          params.fetch(:demographics, {}).permit(:name, :dob, :sex, :marital_status, :religion, :birth_city, :birth_state,
                                                 :employer, :employment_status, :ssn).to_h
        end
      end
    end
  end
end
