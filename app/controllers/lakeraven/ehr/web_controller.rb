# frozen_string_literal: true

module Lakeraven
  module EHR
    # HTML (non-FHIR) base controller for admin / session UI.
    class WebController < ::ActionController::Base
      # Every browser surface in the engine, audited at the base rather than
      # one controller at a time — a clinician-facing page added later is
      # covered on the day it is written, not on the day someone notices.
      # Pages that touch no patient data and name no user (the sign-in form)
      # need no row and are not refused one; see `audit_settled?`.
      include AuditableClinicalAccess

      layout "lakeraven/ehr/application"

      private

      def require_authentication
        return if session[:duz].present?

        redirect_to login_path, alert: "Please sign in"
      end

      def current_security_keys
        Array(session[:security_keys])
      end
    end
  end
end
