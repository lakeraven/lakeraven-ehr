# frozen_string_literal: true

require "rpms_rpc/api/tribal"

module Lakeraven
  module EHR
    module Registration
      # The reasons behind a patient's eligibility status (rpms-ux S-REG-07.3):
      # the ELIGIBILITY MODIFIERS multiple of IHS PATIENT (#9000001.03401). The
      # patient's page lists them; this page changes them.
      class EligibilityModifiersController < PatientSectionController
        EDIT_ACTIONS = %w[create destroy].freeze

        rate_limit only: %i[index create destroy]

        # GET /registration/patients/:dfn/eligibility_modifiers
        def index
          load_page
        end

        # POST /registration/patients/:dfn/eligibility_modifiers
        def create
          modifier = params[:modifier_ien].to_i
          unless modifier.positive?
            load_page
            flash.now[:alert] = "Choose a reason."
            return render(:index, status: :unprocessable_content)
          end

          result = PatientProfileGateway.add_eligibility_modifier(@dfn, modifier)
          if result.saved?
            redirect_to registration_patient_eligibility_modifiers_path(@dfn), notice: "Reason added."
          else
            load_page
            flash.now[:alert] = write_failure_message(result, "reason")
            render :index, status: (result.unknown? ? :service_unavailable : :unprocessable_content)
          end
        end

        # POST /registration/patients/:dfn/eligibility_modifiers/:ien/remove
        def destroy
          result = PatientProfileGateway.remove_eligibility_modifier(@dfn, params[:ien])
          if result.saved?
            redirect_to registration_patient_eligibility_modifiers_path(@dfn), notice: "Reason removed."
          else
            redirect_to registration_patient_eligibility_modifiers_path(@dfn), alert: write_failure_message(result, "removal")
          end
        end

        private

        def load_page
          @modifiers = PatientProfileGateway.eligibility_modifiers(@dfn)
          @status = PatientProfileGateway.enrollment(@dfn)&.dig(:eligibility_status).presence
          @choices = PatientProfileGateway.eligibility_modifier_choices(@status).reject { |row| @modifiers.any? { |m| m[:ien] == row[:ien] } }
        end
      end
    end
  end
end
