# frozen_string_literal: true

module Lakeraven
  module EHR
    # HTML (non-FHIR) base controller for admin / session UI.
    class WebController < ::ActionController::Base
      layout "lakeraven/ehr/application"

      private

      # The idle timeout used to fire only as a side effect of reading the
      # SMART token, so it applied to the FHIR surface and nowhere else:
      # `GET /dashboard` a day later still returned 200. It belongs here, on
      # every authenticated HTML request, and it revokes rather than merely
      # forgetting — CookieStore means the client keeps a valid cookie after
      # reset_session.
      def require_authentication
        if session[:duz].present? && session_idle_expired?
          terminate_session!
          return redirect_to login_path, alert: "Your session timed out. Please sign in again."
        end

        return touch_session! if session[:duz].present?

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

      def current_security_keys
        Array(session[:security_keys])
      end
    end
  end
end
