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
      include PatientBannerRendering
      include RpmsUserScope

      helper ApplicationHelper
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
        if session[:duz].present? && (session_idle_expired? || session_lifetime_expired?)
          terminate_session!
          return redirect_to login_path, alert: "Your session timed out. Please sign in again."
        end
        if session[:duz].present? && session_token_revoked?
          terminate_session!
          return redirect_to login_path, alert: "Your session ended. Please sign in again."
        end
        return end_session_for_closed_rpms! if session[:duz].present? && rpms_connection_closed?

        return touch_session! if session[:duz].present?

        note_audit_denial("browser access refused: not signed in")
        redirect_to login_path, alert: "Please sign in"
      end

      # Whether the credential this session was signed in with is no longer
      # valid: revoked (a sign-in by the same user elsewhere, a sign-out, an
      # administrator) or expired. The session dies with it (ADR 0011 §4). A
      # session that carries no token (the test-only sign-in) has none to check.
      def session_token_revoked?
        raw = session[:smart_token].presence
        return false if raw.nil?

        token = Doorkeeper::AccessToken.by_token(raw)
        token.nil? || token.revoked? || token.expired?
      end

      def session_idle_expired?
        last_seen = session[:last_seen_at]
        return false if last_seen.blank?

        Time.current.to_i - last_seen.to_i > session_idle_limit
      end

      # Whether the session has outlived the site's session_lifetime since
      # sign-on, however active it has been. A session with no sign-on time was
      # not made by sign-on, and ends.
      def session_lifetime_expired?
        signed_in = session[:signed_in_at]
        signed_in.blank? || Time.current.to_i - signed_in.to_i > Lakeraven::EHR.configuration.session_lifetime.to_i
      end

      # How long this session may sit idle: the site's limit, or the user's RPMS
      # limit (their DTIME, read at sign-on) when that is shorter. RPMS may make
      # it stricter, never looser.
      def session_idle_limit
        site = Lakeraven::EHR.configuration.session_idle_limit.to_i
        [ session[:rpms_idle_seconds].presence&.to_i, site ].compact.min
      end

      def touch_session!
        session[:last_seen_at] = Time.current.to_i
        keep_rpms_session_alive!
      end

      # Keep this user's RPMS connection open for as long as they may sit idle;
      # the pool's keeper ends it after (RpmsSessions, SessionPool#touch).
      def keep_rpms_session_alive!
        RpmsSessions.touch(session[:rpms_pool_key], idle_for: session_idle_limit) if RpmsSessions.enabled?
      end

      # RPMS ends an idle broker session on its own clock, and the session was
      # bound at sign-on with the user's codes, which this app does not keep. A
      # closed connection cannot be reopened for them, so the browser session
      # ends too and the user signs in again (a new connection). Pages that read
      # nothing from RPMS stop loading as if it were still there.
      def rpms_connection_closed?
        # Held AND connected: a connection the broker dropped ends the session.
        return !RpmsSessions.live?(session[:rpms_pool_key]) if RpmsSessions.enabled? && session[:rpms_pool_key].present?

        client = RpmsRpc.configuration.client
        client.respond_to?(:connected?) && !client.connected?
      end

      def end_session_for_closed_rpms!
        terminate_session!
        redirect_to login_path, alert: "Your RPMS session ended. Sign in again."
      end

      # End the session AND kill the credential it was carrying. Used by
      # sign-out, idle expiry, a failed sign-on, a broker outage, and a
      # different human signing in at this workstation.
      def terminate_session!
        revoke_session_token!
        RpmsSessions.release(session[:rpms_pool_key]) if RpmsSessions.enabled?
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

      # Whether the signed-in user holds the named capability (Capabilities,
      # ADR 0010), from the keys RPMS reported at sign-on. Views ask the same
      # question, so a control a user sees is one the server allows.
      def capability?(name)
        Capabilities.allows?(current_security_keys, name)
      end
      helper_method :capability?

      # Refuse the request unless the user holds the capability: the one
      # server-side check every screen's before_action uses.
      def require_capability!(name)
        return if capability?(name)

        note_audit_denial("browser access refused: lacks #{name}")
        head :forbidden
      end
    end
  end
end
