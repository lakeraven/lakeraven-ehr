# frozen_string_literal: true

module Lakeraven
  module EHR
    module Registration
      # The migrant, homeless and internet questions (rpms-ux S-REG-11,
      # S-REG-22.5, S-REG-31.3), shown on the patient's registration page
      # (social_statuses/_section). Each answer is a new dated entry in RPMS;
      # the earlier ones are kept.
      class SocialStatusesController < PatientSectionController
        EDIT_ACTIONS = %w[edit update].freeze

        rate_limit only: %i[edit update]

        # GET /registration/patients/:dfn/social_status/edit
        def edit
          @entry = SocialStatusEntry.new
          @current = PatientProfileGateway.social_status(@dfn)
        end

        # POST /registration/patients/:dfn/social_status
        def update
          @entry = SocialStatusEntry.new(entry_params)
          return render_form(:unprocessable_content) unless @entry.valid?

          result = PatientProfileGateway.record_social_status(@dfn, @entry)
          if result.saved?
            redirect_to registration_patient_path(@dfn, anchor: "social-status-section"), notice: "Answers saved."
          else
            flash.now[:alert] = write_failure_message(result, "answers")
            render_form(result.unknown? ? :service_unavailable : :unprocessable_content)
          end
        end

        private

        def entry_params
          params.fetch(:social_status, {}).permit(:migrant, :migrant_type, :homeless, :homeless_type, :internet).to_h
        end

        def render_form(status)
          @current = PatientProfileGateway.social_status(@dfn)
          render :edit, status: status
        end
      end
    end
  end
end
