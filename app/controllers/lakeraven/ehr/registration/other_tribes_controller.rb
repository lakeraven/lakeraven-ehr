# frozen_string_literal: true

require "rpms_rpc/api/tribal"

module Lakeraven
  module EHR
    module Registration
      # A patient's other tribes (rpms-ux S-REG-07.2, 07.8, 07.9): the OTHER
      # TRIBE multiple of IHS PATIENT (#9000001.43). The patient's page lists
      # them (other_tribes/_section); this page changes them.
      class OtherTribesController < PatientSectionController
        EDIT_ACTIONS = %w[create destroy].freeze

        rate_limit only: %i[index create destroy]

        before_action -> { require_site_asks!(:other_tribes, "other tribes") }

        # GET /registration/patients/:dfn/other_tribes?tribe_search=
        def index
          @entry = OtherTribeEntry.new
          load_page
        end

        # POST /registration/patients/:dfn/other_tribes
        def create
          @entry = OtherTribeEntry.new(params.fetch(:other_tribe, {}).permit(:tribe_ien, :quantum).to_h)
          load_page
          return render(:index, status: :unprocessable_content) unless @entry.valid?

          result = PatientProfileGateway.add_other_tribe(@dfn, @entry)
          return redirect_to(registration_patient_other_tribes_path(@dfn), notice: "Other tribe added.") if result.saved?

          @entry.errors.add(result.field || :base, result.message) if result.message.present?
          flash.now[:alert] = write_failure_message(result, "other tribe")
          render :index, status: (result.unknown? ? :service_unavailable : :unprocessable_content)
        end

        # POST /registration/patients/:dfn/other_tribes/:ien/remove
        def destroy
          result = PatientProfileGateway.remove_other_tribe(@dfn, params[:ien])
          if result.saved?
            redirect_to registration_patient_other_tribes_path(@dfn), notice: "Other tribe removed."
          else
            redirect_to registration_patient_other_tribes_path(@dfn), alert: write_failure_message(result, "removal")
          end
        end

        private

        def load_page
          @other_tribes = PatientProfileGateway.other_tribes(@dfn)
          @tribes = PatientRegistrationGateway.tribes(params[:tribe_search])
        end
      end
    end
  end
end
