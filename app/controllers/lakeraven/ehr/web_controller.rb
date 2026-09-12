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

      # The session-surface analogue of the FHIR token scope check: a session
      # that is not a clinical one may not reach clinical data at all. The
      # real RPMS sign-on (#332) resolves `user_type` from the AV CODE
      # response's user class plus security keys, so this gate refuses the
      # sign-ons RPMS itself does not consider clinical.
      CLINICAL_USER_TYPES = %w[provider].freeze

      private

      # This base authenticates by the browser session (`require_authentication`
      # gates on `session[:duz]`), so — uniquely — its pages may be attributed
      # from the session. API/token surfaces never declare this (F1).
      def session_authenticated_surface?
        true
      end

      # The base refusal EVERY inheriting page uses — so the denial is noted
      # HERE, not in per-controller overrides (#512). The first version of that
      # fix noted the denial only in one subclass's override, which left every
      # other browser page's anonymous probes unrecorded (S3): a redirect
      # carries no >=400 status, so without the noted reason the audit saw
      # nothing worth a row.
      #
      # The idle timeout (#486) also lives here rather than firing only as a
      # side effect of reading the SMART token — which applied it to the FHIR
      # surface and nowhere else, so `GET /dashboard` a day later still
      # returned 200. On every authenticated HTML request now, and it REVOKES
      # rather than merely forgetting, because CookieStore leaves the client a
      # valid cookie after reset_session.
      def require_authentication
        if session[:duz].present? && session_idle_expired?
          terminate_session!
          return redirect_to login_path, alert: "Your session timed out. Please sign in again."
        end

        return touch_session! if session[:duz].present?

        note_audit_denial("browser access refused: not signed in")
        redirect_to login_path, alert: "Please sign in"
      end

      def session_idle_expired?
        last_seen = session[:last_seen_at]
        return false if last_seen.blank?

        Time.current.to_i - last_seen.to_i > SmartAuthentication::SESSION_IDLE_TIMEOUT.to_i
      end

      def touch_session!
        session[:last_seen_at] = Time.current.to_i
      end

      # End the session AND kill the credential it was carrying. Used by
      # sign-out, idle expiry, a failed sign-on, a broker outage, and a
      # different human signing in at this workstation.
      def terminate_session!
        revoke_session_token!
        reset_session
      end

      def revoke_session_token!
        raw = session[:smart_token].presence
        return if raw.nil?

        token = Doorkeeper::AccessToken.by_token(raw)
        token.revoke if token && !token.revoked?
      rescue StandardError => e
        Rails.logger.error("Session token revocation failed: #{e.class}")
      end

      def require_clinical_access
        return if CLINICAL_USER_TYPES.include?(session[:user_type].to_s)

        note_audit_denial("browser access refused: sign-on carries no clinical access")
        render plain: "Forbidden: this sign-on does not carry clinical access",
               status: :forbidden
      end

      def current_security_keys
        Array(session[:security_keys])
      end
    end
  end
end
