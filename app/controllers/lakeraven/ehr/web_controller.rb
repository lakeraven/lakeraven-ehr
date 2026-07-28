# frozen_string_literal: true

module Lakeraven
  module EHR
    # HTML (non-FHIR) base controller for admin / session UI.
    class WebController < ::ActionController::Base
      layout "lakeraven/ehr/application"

      private

      def require_authentication
        return if session[:duz].present?

        redirect_to main_app.root_path, alert: "Please sign in"
      end

      def current_security_keys
        Array(session[:security_keys])
      end
    end
  end
end
