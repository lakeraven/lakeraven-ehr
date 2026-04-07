# frozen_string_literal: true

module Lakeraven
  module EHR
    # Engine-wide controller base.
    #
    # Handles two cross-cutting concerns:
    #
    # 1. **Tenant context.** Reads X-Tenant-Identifier and
    #    X-Facility-Identifier from request headers and stuffs them
    #    into Lakeraven::EHR::Current. SMART auth (#52) will replace
    #    the header source with the SMART launch context once it
    #    lands; the rest of the engine doesn't need to care which
    #    flavor populated Current.
    #
    # 2. **FHIR error rendering.** Standardizes 404, 400, and other
    #    error responses as application/fhir+json OperationOutcome
    #    resources rather than the Rails default HTML / JSON.
    class ApplicationController < ActionController::API
      FHIR_CONTENT_TYPE = "application/fhir+json"

      before_action :require_tenant_context!

      private

      def require_tenant_context!
        tenant = request.headers["X-Tenant-Identifier"]
        if tenant.nil? || tenant.empty?
          render_operation_outcome(
            status: :bad_request,
            severity: "error",
            code: "required",
            diagnostics: "X-Tenant-Identifier header is required"
          )
          return
        end
        Current.tenant_identifier   = tenant
        Current.facility_identifier = request.headers["X-Facility-Identifier"].presence
      end

      def render_operation_outcome(status:, severity:, code:, diagnostics: nil)
        outcome = FHIR::OperationOutcome.call(severity: severity, code: code, diagnostics: diagnostics)
        render json: outcome, status: status, content_type: FHIR_CONTENT_TYPE
      end

      def render_fhir(resource, status: :ok)
        render json: resource, status: status, content_type: FHIR_CONTENT_TYPE
      end
    end
  end
end
