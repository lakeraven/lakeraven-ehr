# frozen_string_literal: true

module Lakeraven
  module EHR
    # Engine-wide controller base.
    #
    # Handles two cross-cutting concerns:
    #
    # 1. **Tenant context.** Calls the host-supplied tenant_resolver
    #    on every request, populates Lakeraven::EHR::Current with the
    #    resolved tenant and facility, and renders a 400 OperationOutcome
    #    when the resolver returns blank. The default resolvers read
    #    X-Tenant-Identifier / X-Facility-Identifier headers; host
    #    SaaS apps override these to extract from a subdomain or any
    #    other URL-bound source.
    #
    # 2. **FHIR error rendering.** Standardizes 400/404/4xx error
    #    responses as application/fhir+json OperationOutcome resources
    #    rather than the Rails default HTML / JSON.
    class ApplicationController < ActionController::API
      FHIR_CONTENT_TYPE = "application/fhir+json"

      before_action :require_tenant_context!

      private

      def require_tenant_context!
        tenant = Lakeraven::EHR.configuration.tenant_resolver.call(request)
        if tenant.nil? || tenant.to_s.strip.empty?
          render_operation_outcome(
            status: :bad_request,
            severity: "error",
            code: "required",
            diagnostics: "Tenant context is required"
          )
          return
        end
        Current.tenant_identifier   = tenant
        Current.facility_identifier = Lakeraven::EHR.configuration.facility_resolver.call(request)
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
