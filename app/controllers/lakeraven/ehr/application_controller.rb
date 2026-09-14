# frozen_string_literal: true

module Lakeraven
  module EHR
    class ApplicationController < ActionController::API
      include SmartAuthentication
      include AuditableClinicalAccess

      FHIR_CONTENT_TYPE = "application/fhir+json"

      before_action :authenticate_smart_token!
      before_action :authorize_fhir_scope!

      # Actions that DISCLOSE clinical data even though they are shaped as
      # writes — generating a C-CDA, running a bulk export, requesting an
      # eligibility determination.
      #
      # Verb dispatch alone gets these exactly backwards. Once POST means
      # "needs write", a `system/*.write` token with no read scope anywhere
      # can pull a patient's name and DOB out of a transition of care while
      # being refused `GET /Patient`. They need BOTH: read for what they hand
      # back, write for what they make.
      def self.discloses_clinical_data(*actions)
        before_action(only: actions) { authorize_disclosing_write! }
      end

      private

      # Read AND write, regardless of verb.
      def authorize_disclosing_write!
        return if can_read?(fhir_resource_type) && can_write?(fhir_resource_type)

        missing = can_read?(fhir_resource_type) ? "writing" : "reading"
        render_forbidden("Insufficient scope for #{missing} #{fhir_resource_type}")
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
        bundle = {
          resourceType: "Bundle",
          type: type,
          total: entries.length,
          entry: entries.map { |e| { resource: e } }
        }
        render json: bundle, status: :ok, content_type: FHIR_CONTENT_TYPE
      end
    end
  end
end
