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
      # minted for a browser are recognisable by it, which is what lets them
      # be refused when they turn up anywhere other than the session that
      # minted them.
      BROWSER_SSO_APP_NAME = "Lakeraven EHR Browser SSO"

      # How long a browser session may sit idle before its token stops being
      # accepted. The token's own 12-hour expiry is the outer bound; this is
      # the inner one, and without it a signed-in workstation stayed signed in
      # for half a day of inactivity.
      SESSION_IDLE_TIMEOUT = 30.minutes

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

        # A session-derived token is a browser credential, not a bearer
        # credential. Presented from a header — copied out of a session,
        # replayed from a log, lifted from a proxy — it is refused, and a
        # header token that claims to be one of ours is refused too.
        unless session_token_binding_holds?(token, source)
          render_unauthorized("Invalid or revoked token")
          return
        end

        @current_token = token
        true
      end

      # Check if token can read the given FHIR resource type.
      def can_read?(resource_type)
        return false unless current_token

        scope_permits?(resource_type, %w[read *])
      end

      # Check if token can write the given FHIR resource type (SMART v2).
      def can_write?(resource_type)
        return false unless current_token

        scope_permits?(resource_type, %w[write c *])
      end

      # Authorization for the CURRENT request's HTTP verb. A read scope must
      # never authorize a write: GET/HEAD need read, everything else needs
      # write. The base filter used to call can_read? regardless of method, so
      # `system/*.read` could POST a C-CDA import, create AND delete a bulk
      # export, request an eligibility check, and generate a transition of
      # care.
      READ_METHODS = %w[GET HEAD OPTIONS].freeze

      def can_perform?(resource_type)
        if READ_METHODS.include?(request.request_method)
          can_read?(resource_type)
        else
          can_write?(resource_type)
        end
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

      # Compartment enforcement for INDEXES and SEARCHES, not just #show.
      #
      # A patient-bound token asking for a collection must either name its own
      # compartment or be refused. Requiring a `patient` parameter is not a
      # control — `?patient=1` from a token bound to 999 returned patient 1's
      # observations. An unfiltered index (no patient parameter at all) is a
      # cross-patient read by definition, so a bound token cannot have one.
      def authorize_patient_search!(patient_id)
        return true unless patient_context_scope?

        if patient_id.blank?
          render_forbidden("A patient-scoped token must search within its own patient compartment")
          return false
        end

        authorize_patient_context!(patient_id)
      end

      # Resource types pulled into a bundle by _include / _revinclude are
      # resources the caller is being handed, so they need the caller's scope
      # like any other. Returns the subset the token may actually read.
      def readable_included_types(types)
        Array(types).select { |t| can_read?(t) }
      end

      # DUZ of the signed-in provider, or nil.
      #
      # DECIDED (review finding H5): the DUZ follows the TOKEN, never the
      # ambient session. Authorization is decided by `current_token`, so the
      # identity a write is signed under must come from that same token or the
      # legal record disagrees with the authorization — a request authorized
      # as clerk A could be e-signed as provider B. A session-derived token is
      # only accepted alongside the session that minted it (see
      # #session_token_binding_holds?), and the token carries the DUZ in
      # resource_owner_id, so for browser requests the two agree by
      # construction. A header/system token has no DUZ and gets nil: system
      # callers must not inherit a human's signature.
      def current_duz
        return nil unless current_token
        return nil unless browser_sso_token?(current_token)

        current_token.resource_owner_id&.to_s.presence
      end

      private

      # Returns [token_string, :header | :session].
      def extract_bearer_token
        auth = request.headers["Authorization"]
        if auth.present?
          match = auth.match(/\ABearer\s+(.+)\z/i)
          return [ match&.captures&.first, :header ]
        end

        # Browser session fallback: the sign-on bridge (SessionsController)
        # mints a SMART token and stashes it here, since a browser won't send
        # an Authorization header. API/system callers always use the header
        # above, so this only applies to the logged-in human flow.
        [ session_smart_token, :session ]
      end

      # A browser-session token is valid ONLY when it arrives through the
      # session that minted it AND that session still identifies the same
      # human. Anything else — a session token in a header, a session whose
      # DUZ no longer matches the token's — fails closed.
      def session_token_binding_holds?(token, source)
        return true unless browser_sso_token?(token)
        return false unless source == :session

        duz = session_duz
        duz.present? && token.resource_owner_id.to_s == duz
      end

      def browser_sso_token?(token)
        token.application&.name == BROWSER_SSO_APP_NAME
      end

      # SMART token minted for the current browser session, if any. Guarded
      # because this concern is also included by header-only API controllers
      # that may not have session middleware.
      def session_smart_token
        if session_idle_expired?
          session.delete(:smart_token)
          session.delete(:duz)
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

      # Display name of the signed-in clinician, for the audit trail. Guarded
      # like the DUZ: only meaningful alongside a session-derived token.
      def current_user_name
        return nil unless current_token && browser_sso_token?(current_token)

        session[:user_name].presence
      rescue StandardError
        nil
      end

      def session_duz
        session[:duz].presence
      rescue StandardError
        nil
      end

      def scope_permits?(resource_type, actions)
        token_scopes = current_token.scopes.to_s.split
        allowed = %w[patient user system].flat_map do |context|
          actions.flat_map { |a| [ "#{context}/#{resource_type}.#{a}", "#{context}/*.#{a}" ] }
        end
        (token_scopes & allowed).any?
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
