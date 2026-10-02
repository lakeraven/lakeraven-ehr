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

      def current_security_keys
        Array(session[:security_keys])
      end

      # The RPMS security keys the signed-on user holds, as RPMS names them
      # (SessionsController stores ORWU USERKEYS verbatim). The registration,
      # scheduling and ADT screens gate on these the way BPRM does, on the
      # key names, because rpms-rpc's symbolic registry does not carry the
      # AG/SD/DG keys yet (rpms-rpc#296).
      def current_rpms_keys
        Array(session[:rpms_keys]).map(&:to_s)
      end

      def holds_rpms_key?(*names)
        names.flatten.any? { |name| current_rpms_keys.include?(name.to_s) }
      end

      # Refuse the page unless the user holds one of `any_of` and none of
      # `none_of`; the refusal names the keys so the clerk knows what to ask
      # for, and it is audited as a denial.
      def require_rpms_key!(any_of:, none_of: [], action: "do this")
        held = holds_rpms_key?(any_of) && !holds_rpms_key?(none_of)
        return true if held

        note_audit_denial("browser access refused: none of #{Array(any_of).join(', ')} held") if respond_to?(:note_audit_denial, true)
        render plain: "Forbidden: you need one of the keys #{Array(any_of).join(', ')} to #{action}", status: :forbidden
        false
      end
    end
  end
end
