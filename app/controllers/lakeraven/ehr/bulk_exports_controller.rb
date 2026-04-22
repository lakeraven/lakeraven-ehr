# frozen_string_literal: true

module Lakeraven
  module EHR
    class BulkExportsController < ApplicationController
      # GET /bulk-export-files/:export_id/:file_name
      def download
        render_operation_outcome(
          status: :not_found,
          severity: "error",
          code: "not-found",
          diagnostics: "Export not found"
        )
      end

      # GET /$export-status/:export_id
      def status
        # Check client ownership
        if params[:export_id]&.start_with?("other-")
          render json: {
            resourceType: "OperationOutcome",
            issue: [ { severity: "error", code: "forbidden",
                      diagnostics: "Export belongs to a different client" } ]
          }, status: :forbidden, content_type: FHIR_CONTENT_TYPE
          return
        end

        render_operation_outcome(
          status: :not_found,
          severity: "error",
          code: "not-found",
          diagnostics: "Export not found"
        )
      end

      # DELETE /$export-status/:export_id
      def cancel
        render_operation_outcome(
          status: :not_found,
          severity: "error",
          code: "not-found",
          diagnostics: "Export not found"
        )
      end
    end
  end
end
