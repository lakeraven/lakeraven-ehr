# frozen_string_literal: true

module Lakeraven
  module EHR
    class MeasuresController < ApplicationController
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

      # $import creates Measures, and only a system client may do it.
      def authorize_write_scope!
        return if current_token && scope_permits?(fhir_resource_type, "c", contexts: %w[system])

        render_forbidden("Insufficient scope for writing #{fhir_resource_type}")
      end
    end
  end
end
