# frozen_string_literal: true

module Lakeraven
  module EHR
    class ExportFilesController < ApplicationController
      include ExportOwnership

      # This endpoint serves the export's actual BYTES — one patient's whole
      # record, SSN included. It had no ownership check and no compartment
      # check at all, so the guard on the status endpoint next to it was a
      # sign on the wrong door.
      before_action :authorize_export_owner!

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
    end
  end
end
