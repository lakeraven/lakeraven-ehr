# frozen_string_literal: true

module Lakeraven
  module EHR
    class ExportFilesController < ApplicationController
      # GET /exports/:export_id/files/:file_name
      def show
        export = ExportsController.store[params[:export_id]]

        unless export&.completed?
          return render_not_found("Export", params[:export_id])
        end

        file = export.output_files&.find { |f| f["file_name"] == params[:file_name] }
        unless file
          return render_not_found("File", params[:file_name])
        end

        render plain: file["content"], content_type: "application/fhir+ndjson"
      end

      private

      # The class-name derivation said "ExportFile", which is not a FHIR
      # resource type, and the identifier fell through to nothing (the route
      # carries :export_id and :file_name, never :id) — a row that could not
      # answer which export was read (S11-class, found on #507's review).
      # The audited entity is the EXPORT whose file content was served; the
      # file name is a detail of it, recorded nowhere because file names in
      # this store are resource-type labels, not identifiers.
      def audit_entity_type = "Export"
      def audit_entity_identifier = params[:export_id]
    end
  end
end
