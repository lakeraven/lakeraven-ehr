# frozen_string_literal: true

module Lakeraven
  module EHR
    class ExportFilesController < ApplicationController
      include ExportClientOwnership

      # Org-bound credentials: file content is authorized through ownership
      # of the RESOLVED export (authorize_export_client!, every token) — the
      # export itself was org-authorized at creation.
      organization_scope :result_filtered, only: :show

      # GET /exports/:export_id/files/:file_name
      def show
        export = ExportsController.store[params[:export_id]]
        return render_not_found("Export", params[:export_id]) unless export
        return unless authorize_export_client!(export)

        unless export.completed?
          return render_not_found("Export", params[:export_id])
        end

        file = export.output_files&.find { |f| f["file_name"] == params[:file_name] }
        unless file
          return render_not_found("File", params[:file_name])
        end

        render plain: file["content"], content_type: "application/fhir+ndjson"
      end
    end
  end
end
