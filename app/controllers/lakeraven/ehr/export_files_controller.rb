# frozen_string_literal: true

module Lakeraven
  module EHR
    class ExportFilesController < ApplicationController
      # GET /exports/:export_id/files/:file_name
      # GET /bulk-export-files/:export_id/:file_name
      def show
        export = ExportsController.store[params[:export_id]]

        unless export&.completed?
          return render_not_found("Export", params[:export_id])
        end

        return unless authorize_export_owner!(export)

        file = export.output_files&.find { |f| f["file_name"] == params[:file_name] }
        unless file
          return render_not_found("File", params[:file_name])
        end

        render plain: file["content"], content_type: "application/fhir+ndjson"
      end

      private

      def authorize_export_owner!(export)
        if export.client_id && current_token&.application&.uid != export.client_id
          render_operation_outcome(
            status: :forbidden, severity: "error",
            code: "forbidden", diagnostics: "Export belongs to a different client"
          )
          return false
        end

        true
      end
    end
  end
end
