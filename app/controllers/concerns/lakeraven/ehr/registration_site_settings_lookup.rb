# frozen_string_literal: true

module Lakeraven
  module EHR
    # The signed-on facility's RPMS registration settings, read once per
    # request (RegistrationSettingsGateway, #980), for the registration
    # controllers and their views.
    module RegistrationSiteSettingsLookup
      extend ActiveSupport::Concern

      included do
        helper_method :registration_settings
      end

      private

      def registration_settings = @registration_settings ||= RegistrationSettingsGateway.current

      # Refuses a section the site has switched off in RPMS (#981), back to
      # the patient's page. A section is asked when RPMS could not be read or
      # the site has not answered (RegistrationSiteSettings#ask?).
      def require_site_asks!(switch, what)
        return if registration_settings.ask?(switch)

        redirect_to registration_patient_path(params[:dfn]),
                    alert: "This site does not ask for #{what}: it is turned off in RPMS's registration settings."
      end

      # The status a form refused by its own checks answers with: 503 when the
      # site's required fields could not be read, else 422.
      def refused_form_status(form)
        form.respond_to?(:site_settings_unavailable?) && form.site_settings_unavailable? ? :service_unavailable : :unprocessable_content
      end
    end
  end
end
