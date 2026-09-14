# frozen_string_literal: true

# SMART on FHIR Authentication Concern
# ONC § 170.315(g)(10) — Bearer token auth + scope-based authorization.
#
# Ported from the predecessor app SmartAuthentication.
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
      # sibling branch: #501 introduces the same constant in this same module
      # for its verb-aware authorization, and this file must be correct without
      # it. The `unless defined?` guard keeps each PR correct alone AND silences
      # the `already initialized constant` warning when the two are merged (git
      # concatenates rather than conflicts) — no manual dedupe, no landing-order
      # rule to remember.
      READ_METHODS = %w[GET HEAD OPTIONS].freeze unless defined?(READ_METHODS)

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

      # Was THIS request actually protected against forgery?
      #
      # An earlier version scanned the callback chain for a
      # `verify_authenticity_token` object. That is callback PRESENCE, not
      # per-request enforcement, and it is wrong in two idiomatic cases that
      # both review seats reproduced independently:
      #
      #   * a NON-REJECTING strategy — `protect_from_forgery with: :null_session`
      #     (the standard idiom for a JSON controller) or `:reset_session`. The
      #     callback exists and "runs", but an unverified request proceeds, so a
      #     forged write lands.
      #   * a PER-ACTION skip — `skip_before_action :verify_authenticity_token,
      #     only: :create`. Rails keeps the callback object on the class, so
      #     `.any?` is true, but it does not run for this action.
      #
      # The only case presence got right was an UNCONDITIONAL skip, which
      # removes the object entirely — exactly the one case the old negative
      # control tested, so the suite stayed green over the hole.
      #
      # Ask Rails its own per-request question instead. `verified_request?`
      # recomputes the answer from the request's origin and token every time,
      # independent of whether any callback is scheduled — so a per-action skip
      # of Rails' callback cannot bypass this gate, and a non-rejecting strategy
      # answers false for a forged (tokenless) request.
      #
      # It must be COMBINED with the enabled check, never substituted:
      # `verified_request?` returns TRUE when `protect_against_forgery?` is
      # false (its first clause is `!protect_against_forgery?`), which is
      # exactly where the test environment lives — so on its own it fails open
      # precisely where it would do the most damage.
      #
      # Deliberately conservative: anything unexpected answers false, which
      # costs a browser a write and never grants one.
      def forgery_protection_enforced?
        return false unless respond_to?(:protect_against_forgery?, true)
        return false unless protect_against_forgery?
        return false unless respond_to?(:verified_request?, true)

        verified_request?
      rescue StandardError
        false
      end

      # Check if token can read the given FHIR resource type.
      def can_read?(resource_type)
        return false unless current_token

        scope_permits?(resource_type, %w[read *])
      end

      # Authorization for the CURRENT request's HTTP verb. A read scope must
      # never authorize a write: GET/HEAD/OPTIONS need read, everything else
      # needs write.
      READ_METHODS = %w[GET HEAD OPTIONS].freeze

      def read_request?
        READ_METHODS.include?(request.request_method)
      end

      def can_perform?(resource_type)
        read_request? ? can_read?(resource_type) : can_write?(resource_type)
      end

      # Resource types pulled into a bundle by _include / _revinclude are
      # resources the caller is being handed, so they need the caller's scope
      # like any other read. Returns the subset the token may actually read.
      def readable_included_types(types)
        Array(types).select { |t| can_read?(t) }
      end

      # Check if token can write the given FHIR resource type (SMART v2).
      def can_write?(resource_type)
        return false unless current_token

        scope_permits?(resource_type, %w[write c *])
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

      # Compartment enforcement for INDEXES, SEARCHES and declared writes —
      # not just #show.
      #
      # A patient-bound token asking for a collection, or naming a patient in
      # a write, must either name its own compartment or be refused. Requiring
      # a parameter is not a control — `?patient=1` from a token bound to 999
      # returned patient 1's observations, and `patient_dfn=1` on a POST
      # returned patient 1's entire C-CDA. An operation that names no patient
      # at all is a cross-patient operation by definition, so a bound token
      # cannot issue one.
      def authorize_patient_search!(patient_id)
        return true unless patient_context_scope?

        if patient_id.blank?
          render_forbidden("A patient-scoped token must act within its own patient compartment")
          return false
        end

        authorize_patient_context!(patient_id)
      end

      private

      def scope_permits?(resource_type, actions)
        token_scopes = current_token.scopes.to_s.split
        allowed = %w[patient user system].flat_map do |context|
          actions.flat_map { |a| [ "#{context}/#{resource_type}.#{a}", "#{context}/*.#{a}" ] }
        end
        (token_scopes & allowed).any?
      end

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
        # Authorization header.
        #
        # SCOPED TO THE HTML CHART SURFACE ONLY (see
        # #session_token_fallback_allowed?). The FHIR API descends from
        # ActionController::API — it has no cookie-auth intent, Doorkeeper has no
        # cookie method, and the browser chart renders HTML server-side and never
        # calls it — so applying the cookie fallback there was overreach: a
        # cross-site SameSite=Lax GET would session-authenticate a FHIR read
        # against a bystanding clinician (#512 F1 / security seat #525). The FHIR
        # API is bearer-only; only ChartsController opts in.
        return [ nil, :none ] unless session_token_fallback_allowed?

        [ session_smart_token, :session ]
      end

      # Whether THIS controller may authenticate a browser SESSION token (the
      # cookie-borne SMART token the sign-on bridge stashes). Default: NO. Only
      # the server-rendered HTML chart (ChartsController, an
      # ActionController::Base) overrides this to true; every FHIR API
      # controller (ActionController::API) stays bearer-only.
      def session_token_fallback_allowed?
        false
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
        note_audit_denial(message) if respond_to?(:note_audit_denial, true)
        render json: {
          resourceType: "OperationOutcome",
          issue: [ { severity: "error", code: "login", diagnostics: message } ]
        }, status: :unauthorized, content_type: "application/fhir+json"
      end

      def render_forbidden(message = "Forbidden")
        note_audit_denial(message) if respond_to?(:note_audit_denial, true)
        render json: {
          resourceType: "OperationOutcome",
          issue: [ { severity: "error", code: "forbidden", diagnostics: message } ]
        }, status: :forbidden, content_type: "application/fhir+json"
      end
    end
  end
end
