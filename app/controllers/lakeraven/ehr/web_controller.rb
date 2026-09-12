# frozen_string_literal: true

module Lakeraven
  module EHR
    # HTML (non-FHIR) base controller for admin / session UI.
    class WebController < ::ActionController::Base
      layout "lakeraven/ehr/application"

      # The session-surface analogue of the FHIR token scope check: a session
      # that is not a clinical one may not reach clinical data at all. These
      # are the user types the interim canned sign-on (#401) can issue; the
      # real VistA sign-on (#332) carries RPMS security keys and person class,
      # and this check becomes a key check against them.
      CLINICAL_USER_TYPES = %w[provider].freeze

      private

      def require_authentication
        return if session[:duz].present?

        redirect_to login_path, alert: "Please sign in"
      end

      def require_clinical_access
        return if CLINICAL_USER_TYPES.include?(session[:user_type].to_s)

        render plain: "Forbidden: this sign-on does not carry clinical access",
               status: :forbidden
      end

      def current_security_keys
        Array(session[:security_keys])
      end
    end
  end
end
