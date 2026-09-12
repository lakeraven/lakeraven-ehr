# frozen_string_literal: true

module Lakeraven
  module EHR
    class ApplicationController < ActionController::API
      include SmartAuthentication
      include AuditableClinicalAccess

      FHIR_CONTENT_TYPE = "application/fhir+json"

      before_action :authenticate_smart_token!
      before_action :authorize_fhir_scope!

      private

      def fhir_resource_type
        self.class.name.demodulize.delete_suffix("Controller").singularize
      end

      # Verb-aware. A read scope authorizes reads; anything that changes state
      # needs a write scope. This used to call can_read? for every verb, so a
      # `system/*.read` token could POST a C-CDA import, create and delete a
      # bulk export, run an eligibility check, and generate a transition of
      # care — all of them state changes behind a read-only credential.
      def authorize_fhir_scope!
        return if can_perform?(fhir_resource_type)

        if READ_METHODS.include?(request.request_method)
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
