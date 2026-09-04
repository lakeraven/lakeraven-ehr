# frozen_string_literal: true

module Lakeraven
  module EHR
    class MeasuresController < ApplicationController
      # Reviewed decision (PR #460 security panel): directory/terminology
      # resources carry no per-patient PHI, and org-bound connectors need
      # them to interpret clinical references — so they stay readable to any
      # authenticated credential. Known residual: this lets an org-bound
      # credential enumerate the shared directory (tenant existence), which
      # is accepted for now and revisited if directories become per-tenant.
      # $import also carries no per-patient PHI (it writes measure
      # DEFINITIONS); it stays additionally gated on a system write scope
      # below, which read-only connector registrations never hold.
      organization_scope :not_patient_compartment, only: %i[index import]
      skip_before_action :authorize_fhir_scope!, only: :import
      before_action :authorize_write_scope!, only: :import

      def index
        measures = Measure.all
        render_bundle(measures.map(&:to_fhir))
      end

      def import
        body = request.body.read
        resource = JSON.parse(body) rescue nil

        unless resource
          render_operation_outcome(status: :bad_request, severity: "error",
                                  code: "invalid", diagnostics: "Invalid JSON")
          return
        end

        service = MeasureImportService.new
        result = service.import_from_resource(resource)

        if result.success?
          render json: {
            resourceType: "OperationOutcome",
            issue: [ { severity: "information", code: "informational",
                       diagnostics: "Measure #{result.measure_id} imported successfully" } ]
          }, status: :ok, content_type: FHIR_CONTENT_TYPE
        else
          render_operation_outcome(status: :unprocessable_entity, severity: "error",
                                  code: "invalid", diagnostics: result.errors.join(", "))
        end
      end

      private

      def authorize_write_scope!
        return if can_write?(fhir_resource_type)

        render_forbidden("Insufficient scope for writing #{fhir_resource_type}")
      end

      def can_write?(resource_type)
        return false unless current_token

        token_scopes = current_token.scopes.to_s.split
        allowed = [
          "system/#{resource_type}.write", "system/#{resource_type}.*",
          "system/*.write", "system/*.*"
        ]
        (token_scopes & allowed).any?
      end
    end
  end
end
