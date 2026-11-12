# frozen_string_literal: true

module Lakeraven
  module EHR
    module Scheduling
      # A clinic's scheduling settings and letters (rpms-ux S-SCH-15). Anyone who
      # may open scheduling and see the clinic sees them; changing them takes
      # SDZSUP, as BPRM's clinic configuration does (S-SCH-15.4). They are read
      # from and filed to RPMS each time (ClinicSettingsGateway).
      class ClinicSettingsController < BaseController
        rate_limit only: %i[show edit update]

        before_action :require_supervisor!, only: %i[edit update]
        before_action :load_resource!
        before_action :require_clinic!
        helper_method :supervisor?

        # GET /scheduling/clinics/:resource_id/settings
        def show
          @settings = ClinicSettingsGateway.read(@resource)
          @warning = ClinicSettingsGateway.warning(@settings)
        end

        # GET /scheduling/clinics/:resource_id/settings/edit
        def edit
          @settings = ClinicSettingsGateway.read(@resource)
          @form = ClinicSettings.from_rpms(@settings)
          load_choices
        end

        # POST /scheduling/clinics/:resource_id/settings
        def update
          @form = ClinicSettings.new(settings_params)
          @settings = ClinicSettingsGateway.read(@resource)
          load_choices
          return render(:edit, status: :unprocessable_content) unless @form.valid?

          @result = ClinicSettingsGateway.save(@form, @resource)
          case @result.status
          when :saved, :unchanged
            flash[:notice] = @result.status == :saved ? "Settings saved." : "Nothing was changed."
            redirect_to scheduling_clinic_settings_path(@resource[:id])
          when :refused
            render :edit, status: :unprocessable_content
          else
            flash.now[:alert] = "RPMS did not confirm the change. Open the clinic's settings again to see what it holds."
            render :edit, status: :service_unavailable
          end
        end

        private

        def require_clinic!
          return if @resource[:hospital_location_id].to_i.positive?

          render plain: "#{@resource[:name]} is not a clinic in RPMS", status: :not_found
        end

        def require_supervisor!
          return if supervisor?

          render plain: "Changing a clinic's settings takes the scheduling supervisor key (SDZSUP)", status: :forbidden
        end

        def load_choices
          @letters = ClinicSettingsGateway.letters
          @clinic_codes = ClinicSettingsGateway.clinic_codes
        end

        def settings_params
          names = %i[abbreviation] + ClinicSettings::NUMBERS + ClinicSettings::FLAGS + ClinicSettings::POINTERS
          params.fetch(:settings, {}).permit(*names).to_h
        end
      end
    end
  end
end
