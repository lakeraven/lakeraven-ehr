# frozen_string_literal: true

# SMART on FHIR Authentication Concern
# ONC § 170.315(g)(10) — Bearer token auth + scope-based authorization.
#
# Ported from rpms_redux SmartAuthentication.
module Lakeraven
  module EHR
    module SmartAuthentication
      extend ActiveSupport::Concern

      # Doorkeeper application that owns every browser-session token. Tokens
      # minted for a browser are recognisable by it, which is what lets them be
      # refused when they turn up anywhere other than the session that minted
      # them. #491's screening surface depends on this predicate — keep its
      # semantics stable.
      BROWSER_SSO_APP_NAME = "Lakeraven EHR Browser SSO"

      # How long a browser session may sit idle before its token stops being
      # accepted. The token's own 12-hour expiry is the outer bound; this is
      # the inner one, and without it a signed-in workstation stayed signed in
      # for half a day of inactivity.
      SESSION_IDLE_TIMEOUT = 30.minutes

      # GET/HEAD/OPTIONS are reads. Defined here rather than assumed from a
      # sibling branch: #501 introduces the same helper for its verb-aware
      # authorization, and this file must be correct without it.
      READ_METHODS = %w[GET HEAD OPTIONS].freeze

      included do
        attr_reader :current_token
      end

      def authenticate_smart_token!
        token_string, source = extract_bearer_token

        if token_string.blank?
          render_unauthorized("No Bearer token provided")
          return
        end

        token = Doorkeeper::AccessToken.by_token(token_string)

        if token.nil? || token.revoked?
          render_unauthorized("Invalid or revoked token")
          return
        end

        if token.expired?
          render_unauthorized("Token has expired")
          return
        end

        # A session-derived token is a BROWSER credential, not a bearer
        # credential. Presented from a header — copied out of a session,
        # replayed from a log, lifted from a proxy — it is refused, and a
        # header token claiming to be one of ours is refused too.
        unless session_token_binding_holds?(token, source)
          render_unauthorized("Invalid or revoked token")
          return
        end

        # THE LANDING CONTRACT (see also #491).
        #
        # A cookie rides cross-site requests, so a session-derived token can be
        # driven by a hostile page — reproduced with no Authorization header,
        # no CSRF token and `Origin: https://evil.example`. What stops that is
        # forgery protection, and `ActionController::API` has none.
        #
        # So the rule is NOT "session tokens cannot write". It is:
        #
        #   A SESSION-DERIVED TOKEN MAY NOT WRITE WHERE FORGERY PROTECTION IS
        #   NOT ACTUALLY ENFORCED FOR THIS REQUEST.
        #
        # Reads are unaffected everywhere. On a CSRF-protected route — a
        # WebController descendant that really runs verify_authenticity_token —
        # a browser session may write, and still has to satisfy everything else
        # it already satisfies: scope, patient compartment, DUZ binding,
        # revocation, idle timeout. Header/system callers are unaffected
        # throughout; they do not ride a cookie and cannot be driven cross-site.
        #
        # The discriminator is the PROTECTION, never the class name — a
        # subclass that skips verify_authenticity_token must not inherit write
        # capability from its parent (see #forgery_protection_enforced?).
        if source == :session && browser_sso_token?(token) &&
           !read_request? && !forgery_protection_enforced?
          render_unauthorized(
            "A browser session may not drive a state-changing request without CSRF protection"
          )
          return
        end

        @current_token = token
        true
      end

      def read_request?
        READ_METHODS.include?(request.request_method)
      end

      # Is Rails' forgery protection GENUINELY active for this request?
      #
      # Three things have to be true, and all three are checked rather than
      # assumed:
      #
      #   1. the controller mixes in RequestForgeryProtection at all —
      #      ActionController::API does not;
      #   2. `protect_against_forgery?` is on (the app-level config);
      #   3. `verify_authenticity_token` is ACTUALLY in this controller's
      #      callback chain — a subclass that skips it has no protection, and
      #      must not inherit write capability from a parent that does.
      #
      # Deliberately conservative: anything unexpected answers false, which
      # costs a browser a write and never grants one.
      def forgery_protection_enforced?
        return false unless respond_to?(:protect_against_forgery?, true)
        return false unless protect_against_forgery?

        self.class._process_action_callbacks.any? do |callback|
          callback.kind == :before && callback.filter == :verify_authenticity_token
        end
      rescue StandardError
        false
      end

      # Check if token can read the given FHIR resource type.
      def can_read?(resource_type)
        return false unless current_token

        token_scopes = current_token.scopes.to_s.split
        allowed = [
          "patient/#{resource_type}.read", "patient/#{resource_type}.*",
          "patient/*.read", "patient/*.*",
          "user/#{resource_type}.read", "user/#{resource_type}.*",
          "user/*.read", "user/*.*",
          "system/#{resource_type}.read", "system/#{resource_type}.*",
          "system/*.read", "system/*.*"
        ]
        (token_scopes & allowed).any?
      end

      # Check if token can write the given FHIR resource type (SMART v2).
      def can_write?(resource_type)
        return false unless current_token

        token_scopes = current_token.scopes.to_s.split
        allowed = [
          "patient/#{resource_type}.write", "patient/#{resource_type}.c", "patient/#{resource_type}.*",
          "patient/*.write", "patient/*.c", "patient/*.*",
          "user/#{resource_type}.write", "user/#{resource_type}.c", "user/#{resource_type}.*",
          "user/*.write", "user/*.c", "user/*.*",
          "system/#{resource_type}.write", "system/#{resource_type}.c", "system/#{resource_type}.*",
          "system/*.write", "system/*.c", "system/*.*"
        ]
        (token_scopes & allowed).any?
      end

      # Enforce patient compartment for patient-context tokens.
      #
      # Binding is checked whenever the token carries ANY patient/ scope: a
      # mixed-scope token (patient/ alongside system/ or user/) stays bound to
      # its patient compartment — broader scopes must not bypass the binding
      # (independent security review finding). Tokens with no patient/ scope
      # (pure system/, user/, or non-clinical scopes) are unbound.
      def authorize_patient_context!(patient_id)
        return true unless patient_context_scope?

        bound = current_token.resource_owner_id.to_s
        if bound.blank? || bound != patient_id.to_s
          render_forbidden("Patient context mismatch")
          return false
        end

        true
      end

      private

      def extract_bearer_token
        # Returns [token_string, :header | :session] — the SOURCE matters, and
        # is what the browser-credential rules below are decided on.
        auth = request.headers["Authorization"]
        if auth.present?
          match = auth.match(/\ABearer\s+(.+)\z/i)
          return [ match&.captures&.first, :header ]
        end

        # Browser session fallback: the sign-on bridge (SessionsController) mints
        # a SMART token and stashes it here, since a browser won't send an
        # Authorization header. API/system callers always use the header above,
        # so this only applies to the logged-in human flow.
        [ session_smart_token, :session ]
      end

      # A browser-session token is valid ONLY when it arrives through the
      # session that minted it AND that session still identifies the same
      # human. Anything else — a session token in a header, a session whose DUZ
      # no longer matches the token's — fails closed.
      def session_token_binding_holds?(token, source)
        return true unless browser_sso_token?(token)
        return false unless source == :session

        duz = session_duz
        duz.present? && token.resource_owner_id.to_s == duz
      end

      # PUBLIC PREDICATE (#491 calls this rather than keeping its own).
      #
      # Is this token a BROWSER credential — minted by the sign-on bridge for a
      # cookie-carrying session — as opposed to a bearer credential held by a
      # system client?
      #
      # Keyed on an intrinsic, immutable flag stamped on the TOKEN at mint
      # time. It used to compare `application.name`, which is a mutable display
      # string with no unique index: two applications can share it, and a
      # rename silently re-classifies every live token. That is not a cosmetic
      # problem — a browser token that stops being recognised stops being
      # BOUND, so it becomes replayable from an Authorization header, which is
      # exactly what the binding exists to prevent. An authorization decision
      # must not hang off an editable label.
      #
      # FAILS TOWARD "BROWSER", deliberately, and this is the one place I read
      # the gate's suggestion the other way round. Misclassifying a system
      # token as a browser token costs that client a 401 — an availability
      # failure, loud and immediate. Misclassifying a browser token as a system
      # token unbinds it — a silent security failure. Ambiguity therefore
      # resolves to "browser": where several applications share the SSO name
      # they are all SSO applications, so nothing legitimate is caught by it.
      def browser_sso_token?(token = current_token)
        return false if token.nil?
        return true if browser_session_flag(token)

        # Tokens minted before the flag existed, and installs that have not run
        # the migration yet.
        legacy_browser_sso_token?(token)
      end

      # SMART token minted for the current browser session, if any. Guarded
      # because this concern is also included by header-only API controllers
      # that may not have session middleware.
      def session_smart_token
        if session_idle_expired?
          # Clearing the session is not revocation: CookieStore means the client
          # still holds a self-contained, still-valid cookie. The credential
          # itself has to die.
          revoke_session_smart_token!
          return nil
        end

        token = session[:smart_token].presence
        session[:last_seen_at] = Time.current.to_i if token
        token
      rescue StandardError
        nil
      end

      def session_idle_expired?
        last_seen = session[:last_seen_at]
        return false if last_seen.blank?

        Time.current.to_i - last_seen.to_i > SESSION_IDLE_TIMEOUT.to_i
      end

      # Revoke whatever SMART token this session carries, then clear it. Every
      # path that ends a session goes through here or WebController's
      # equivalent — sign-out, idle expiry, a failed sign-on, a broker outage,
      # and a DIFFERENT human signing in at the same workstation.
      def revoke_session_smart_token!
        raw = session[:smart_token].presence
        if raw
          token = Doorkeeper::AccessToken.by_token(raw)
          token.revoke if token && !token.revoked?
        end
        session.delete(:smart_token)
        session.delete(:duz)
        session.delete(:last_seen_at)
      rescue StandardError => e
        Rails.logger.error("Session token revocation failed: #{e.class}")
      end

      def session_duz
        session[:duz].presence
      rescue StandardError
        nil
      end

      # The intrinsic marker. Absent column (migration not yet run) answers
      # false and lets the legacy path decide.
      def browser_session_flag(token)
        return false unless token.respond_to?(:has_attribute?)
        return false unless token.has_attribute?(:browser_session)

        token.browser_session == true
      rescue StandardError
        false
      end

      # Pre-flag fallback. Resolves by application NAME, which is why it is the
      # fallback and not the rule; any match counts, per the ambiguity note on
      # #browser_sso_token?.
      def legacy_browser_sso_token?(token)
        token.application&.name == BROWSER_SSO_APP_NAME
      rescue StandardError
        false
      end

      # DUZ of the clinician this request acts as, or nil.
      #
      # DECIDED (review finding H5): the DUZ follows the TOKEN, never the
      # ambient session. Authorization is decided by `current_token`, so the
      # identity a write is signed under must come from that same token or the
      # legal record disagrees with the authorization — a request authorized as
      # clerk A could be e-signed as provider B. A session-derived token is only
      # accepted alongside the session that minted it, and carries the DUZ in
      # resource_owner_id, so for browser requests the two agree by
      # construction. A header/system token has no DUZ and gets nil: system
      # callers must not inherit a human's signature.
      def current_duz
        return nil unless current_token && browser_sso_token?(current_token)
        # resource_owner_id carries the DUZ for a browser token and the patient
        # DFN for a patient-context token — two identifier namespaces in one
        # column, compared with ==. SessionsController refuses to mint a
        # browser token with a patient/ scope, and this refuses to READ one as
        # a DUZ, so the namespaces cannot meet even if minting is bypassed.
        return nil if patient_context_scope?

        current_token.resource_owner_id&.to_s.presence
      end

      # Display name of the signed-in clinician, for the audit trail.
      def current_user_name
        return nil unless current_token && browser_sso_token?(current_token)

        session[:user_name].presence
      rescue StandardError
        nil
      end

      def patient_context_scope?
        current_token&.scopes&.to_s&.match?(%r{\bpatient/})
      end

      def user_context_scope?
        current_token&.scopes&.to_s&.match?(%r{\buser/})
      end

      def system_scope?
        current_token&.scopes&.to_s&.match?(%r{\bsystem/})
      end

      def render_unauthorized(message = "Unauthorized")
        render json: {
          resourceType: "OperationOutcome",
          issue: [ { severity: "error", code: "login", diagnostics: message } ]
        }, status: :unauthorized, content_type: "application/fhir+json"
      end

      def render_forbidden(message = "Forbidden")
        render json: {
          resourceType: "OperationOutcome",
          issue: [ { severity: "error", code: "forbidden", diagnostics: message } ]
        }, status: :forbidden, content_type: "application/fhir+json"
      end
    end
  end
end
