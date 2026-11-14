# frozen_string_literal: true

module Lakeraven
  module EHR
    class ApplicationController < ActionController::API
      # First: a closed disclosure surface (#968) is refused in #process,
      # before anything else here runs.
      include DisclosureSurfaceGate
      include SmartAuthentication
      include AuditableClinicalAccess
      include RateLimitable
      include FHIRReadEgress
      include FHIRSearchBundle
      include FeatureUnavailableRendering

      FHIR_CONTENT_TYPE = "application/fhir+json"

      before_action :authenticate_smart_token!
      before_action :authorize_fhir_scope!
      # A withheld endpoint reports itself unavailable (#647) before any
      # request parameter is judged, so a malformed one cannot turn
      # not-supported into a 400. After the token checks, so an
      # unauthenticated or out-of-scope caller learns nothing from it.
      before_action :ensure_backend_supports_interaction!
      # Every index here is a FHIR search. Its result parameters are checked
      # after the token, so an unauthenticated or out-of-scope caller learns
      # nothing from a 400.
      before_action :validate_fhir_paging!, if: :fhir_search?
      before_action :validate_fhir_sort_and_include!, if: :fhir_search?
      # A launched token reads RPMS on its user's own connection (#844, ADR
      # 0011), and a Backend Services token on the service account's (#996,
      # ADR 0011 §6), after every check above has passed. Any other token has
      # none.
      around_action :run_on_rpms_connection

      # Actions that DISCLOSE clinical data even though they are shaped as
      # writes — generating a C-CDA, running a bulk export, requesting an
      # eligibility determination.
      #
      # Verb dispatch alone gets these exactly backwards. Once POST means
      # "needs write", a token with no read scope anywhere can pull a patient's
      # name and DOB out of a transition of care while being refused
      # `GET /Patient`. They need BOTH: write for what they make, read for what
      # they hand back.
      #
      # `reads:` NAMES THE TYPES IN THE PAYLOAD, and is mandatory. An earlier
      # version checked `can_read?(fhir_resource_type)`, and that type comes
      # from the CONTROLLER CLASS NAME — "TransitionsOfCare", "Export" — which
      # is not a FHIR resource and is not what is being handed back. A token
      # scoped `system/TransitionsOfCare.read+write` satisfied it and still
      # extracted a patient's name and DOB. Only a token with no read scope at
      # all was caught.
      #
      # ChartsController has the same shape: it requires Patient read for the
      # whole request and gates each section on its own type.
      def self.discloses_clinical_data(*actions, reads:)
        types = Array(reads).freeze
        raise ArgumentError, "discloses_clinical_data needs the types it discloses" if types.empty?

        before_action(only: actions) { authorize_disclosing_write!(types) }
      end

      private

      def run_on_rpms_connection(&action)
        return RpmsSessions.with_service_account(current_token, &action) if backend_services_token?

        run_on_launched_users_connection(&action)
      end

      # A SMART Backend Services token: a client application's own, with no
      # person behind it. Not launched, not a browser session's, no resource
      # owner, and every scope it carries is system/. Anything else (a user/ or
      # patient/ scope, openid, launch/..., offline_access) is not one, and
      # never rides the service account.
      def backend_services_token?
        return false unless current_token && RpmsSessions.enabled?
        return false if current_token.resource_owner_id.present? || launched_authorization ||
                        browser_sso_token?(current_token)

        raw = current_token.scopes.to_a.map(&:to_s)
        return false unless raw.all? { |scope| scope.start_with?("system/") }

        scopes = SmartScope.parse_all(raw)
        scopes.any? && scopes.all? { |scope| scope.context == "system" }
      end

      # The request runs inside the approving user's RPMS connection
      # (RpmsSessions.with_user), so every RPC it makes runs as that user. Using
      # the token counts as the user's activity and keeps the connection open
      # for their idle limit; it never extends the session past its lifetime,
      # because the token itself expires first (SmartAuthorization).
      # authenticate_smart_token! has already refused a token whose session or
      # connection is gone; one that went in between answers 401.
      def run_on_launched_users_connection(&action)
        authorization = launched_authorization
        return action.call unless authorization && RpmsSessions.enabled?

        RpmsSessions.touch(authorization.pool_key, idle_for: launched_idle_limit(authorization))
        RpmsSessions.with_user(authorization.pool_key, &action)
      rescue RpmsSessions::SignInAgain, RpmsRpc::SessionPool::PoolExhaustedError
        current_token.revoke unless current_token.revoked?
        render_unauthorized("Invalid or revoked token")
      end

      # The user's RPMS idle limit when shorter than the site's (WebController).
      def launched_idle_limit(authorization)
        site = Lakeraven::EHR.configuration.session_idle_limit.to_i
        [ authorization.rpms_idle_seconds, site ].compact.min
      end

      # Write scope for the operation, read scope for EVERY type it discloses.
      def authorize_disclosing_write!(disclosed_types)
        unless can_write?(fhir_resource_type)
          return render_forbidden("Insufficient scope for writing #{fhir_resource_type}")
        end

        missing = disclosed_types.reject { |type| can_read?(type) }
        return if missing.empty?

        render_forbidden("Insufficient scope for reading #{missing.join(', ')}")
      end

      def fhir_resource_type
        self.class.name.demodulize.delete_suffix("Controller").singularize
      end

      # Verb-aware. A read scope authorizes reads; anything that changes state
      # needs a write scope. This used to call can_read? for every verb, so a
      # `system/*.read` token could POST a C-CDA import, create and delete a
      # bulk export, run an eligibility check, and generate a transition of
      # care — all state changes behind a read-only credential.
      def authorize_fhir_scope!
        return if can_perform?(fhir_resource_type)

        if read_request?
          render_forbidden("Insufficient scope for reading #{fhir_resource_type}")
        else
          render_forbidden("Insufficient scope for writing #{fhir_resource_type}")
        end
      end

      def authorize_fhir_write_scope!
        return if can_write?(fhir_resource_type)

        render_forbidden("Insufficient scope for writing #{fhir_resource_type}")
      end

      # A configured supplemental provider that fails makes the chart INCOMPLETE,
      # so the read fails rather than returning a partial list that reads as a
      # whole one. The diagnostics are deliberately generic: the exception
      # message and the DFN stay in the server log, because this response field
      # is caller-visible and the same reasoning as the audit note below applies
      # -- a rescued message is free text that can carry PHI.
      # An API request carries a token, not a signed-in user's RPMS connection,
      # and this process holds no shared one (ADR 0011). A Backend Services
      # token reads on the deployment's service account (ADR 0011 §6) when one
      # is configured; with none, or when its sign-on fails, it lands here. A
      # request that reaches for RPMS with no connection of its own is refused,
      # never served on another user's connection.
      rescue_from RpmsRpc::NotConfiguredError do
        Rails.logger.warn("[rpms] API request with no RPMS identity: #{controller_path}##{action_name}")
        render_operation_outcome(
          status: :service_unavailable,
          severity: "error",
          code: "transient",
          diagnostics: "This request has no RPMS connection of its own."
        )
      end

      rescue_from Lakeraven::EHR::SupplementalProviderError do |error|
        Rails.logger.error("supplemental clinical provider failed: #{error.message}")
        render_operation_outcome(
          status: :internal_server_error,
          severity: "error",
          code: "exception",
          diagnostics: "A configured supplemental clinical data provider failed."
        )
      end

      def render_operation_outcome(status:, severity:, code:, diagnostics: nil)
        outcome = {
          resourceType: "OperationOutcome",
          issue: [ { severity: severity, code: code, diagnostics: diagnostics }.compact ]
        }
        render json: outcome, status: status, content_type: FHIR_CONTENT_TYPE
        # The audit gets the STABLE outcome code and status, never the
        # diagnostics: several callers build diagnostics from
        # request-controlled values and rescued exception MESSAGES — free
        # text that can carry PHI into a log built to hold none (review
        # finding on #512). The full diagnostics stay in the HTTP response,
        # which is where the caller needs them.
        note_audit_denial("fhir operation refused: #{code} (HTTP #{response.status})") if severity == "error"
      end

      def render_fhir(resource, status: :ok)
        render json: resource, status: status, content_type: FHIR_CONTENT_TYPE
      end

      def render_not_found(resource_type, id)
        render_operation_outcome(
          status: :not_found,
          severity: "error",
          code: "not-found",
          diagnostics: "#{resource_type}/#{id} not found"
        )
      end

      def render_bundle(entries, type: "searchset")
        render json: fhir_subset_bundle(fhir_search_bundle(entries, type: type)), status: :ok, content_type: FHIR_CONTENT_TYPE
      end
    end
  end
end
