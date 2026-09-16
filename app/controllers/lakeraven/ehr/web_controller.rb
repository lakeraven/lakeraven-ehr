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

      # The base refusal EVERY inheriting page uses — so the denial is noted
      # HERE, not in per-controller overrides. The first version of this fix
      # noted the denial only in one subclass's override, which left every
      # other browser page's anonymous probes unrecorded (S3): a redirect
      # carries no >=400 status, so without the noted reason the audit saw
      # nothing worth a row.
      def require_authentication
        return if session[:duz].present?

        note_audit_denial("browser access refused: not signed in")
        redirect_to login_path, alert: "Please sign in"
      end

      def current_security_keys
        Array(session[:security_keys])
      end
    end
  end
end
