# frozen_string_literal: true

module Lakeraven
  module EHR
    module Registration
      # The other names a patient has used (rpms-ux S-REG-12.2-12.4): the ALIAS
      # multiple of PATIENT (#2.01), which the patient search also looks in. The
      # patient's page lists them (other_names/_section); this page changes them.
      class OtherNamesController < PatientSectionController
        EDIT_ACTIONS = %w[create destroy].freeze

        # GET /registration/patients/:dfn/other_names
        def index
          @other_name = OtherNameEntry.new
          @other_names = PatientProfileGateway.aliases(@dfn)
        end

        # POST /registration/patients/:dfn/other_names
        def create
          @other_name = OtherNameEntry.new(name: params.dig(:other_name, :name))
          return render_index(:unprocessable_content) unless @other_name.valid?

          result = PatientProfileGateway.add_alias(@dfn, @other_name.name)
          return redirect_to(registration_patient_other_names_path(@dfn), notice: "Other name added.") if result.saved?

          @other_name.errors.add(:name, result.message) if result.field && result.message.present?
          flash.now[:alert] = write_failure_message(result, "other name")
          render_index(result.unknown? ? :service_unavailable : :unprocessable_content)
        end

        # POST /registration/patients/:dfn/other_names/:ien/remove
        def destroy
          result = PatientProfileGateway.remove_alias(@dfn, params[:ien])
          if result.saved?
            redirect_to registration_patient_other_names_path(@dfn), notice: "Other name removed."
          else
            redirect_to registration_patient_other_names_path(@dfn), alert: write_failure_message(result, "removal")
          end
        end

        private

        def render_index(status)
          @other_names = PatientProfileGateway.aliases(@dfn)
          render :index, status: status
        end
      end
    end
  end
end
