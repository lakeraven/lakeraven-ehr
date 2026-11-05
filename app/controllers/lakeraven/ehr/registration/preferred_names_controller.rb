# frozen_string_literal: true

module Lakeraven
  module EHR
    module Registration
      # The name the patient goes by (rpms-ux S-REG-12.1), shown on the patient's
      # registration page (preferred_names/_section). RPMS has no registration
      # call for it, so the gem files the field the way IHS's own API does
      # (rpms-ops#1059).
      class PreferredNamesController < PatientSectionController
        EDIT_ACTIONS = %w[edit update].freeze

        # GET /registration/patients/:dfn/preferred_name/edit
        def edit
          @entry = PreferredNameEntry.new(name: PatientProfileGateway.preferred_name(@dfn))
        end

        # POST /registration/patients/:dfn/preferred_name
        def update
          @entry = PreferredNameEntry.new(name: params.dig(:preferred_name, :name))
          return render(:edit, status: :unprocessable_content) unless @entry.valid?

          result = PatientProfileGateway.set_preferred_name(@dfn, @entry.name)
          if result.saved?
            notice = @entry.name.empty? ? "Preferred name cleared." : "Preferred name saved."
            redirect_to registration_patient_path(@dfn, anchor: "preferred-name-section"), notice: notice
          else
            flash.now[:alert] = write_failure_message(result, "preferred name")
            render :edit, status: (result.unknown? ? :service_unavailable : :unprocessable_content)
          end
        end
      end
    end
  end
end
