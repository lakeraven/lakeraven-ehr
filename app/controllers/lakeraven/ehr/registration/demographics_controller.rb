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
          @demographics.site_settings = registration_settings
          @dob_restricted = dob_restricted?
          render_form(:ok)
        end

        # PATCH /registration/patients/:dfn/demographics
        def update
          attributes = demographics_params
          @dob_restricted = dob_restricted?
          attributes[:dob] = @record[:dob] if @dob_restricted && !attributes.key?(:dob)
          @demographics = PatientDemographics.new(attributes)
          @demographics.site_settings = registration_settings
          valid = @demographics.valid?
          if @dob_restricted && @demographics.dob != @record[:dob]
            @dob_error = "Date of birth can only be changed by a registration manager"
            @demographics.errors.add(:base, @dob_error)
            note_audit_denial("date of birth change refused: registration manager required")
            @demographics.dob = @record[:dob]
            return render_form(:unprocessable_content)
          end
          return render_form(refused_form_status(@demographics)) unless valid

          save(@demographics, PatientDemographics.from_record(@record), "Demographics saved.")
        end

        private

        def dob_restricted?
          registration_settings.limited_dob_editing? && !capability?("patient.correct_dob")
        end

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
