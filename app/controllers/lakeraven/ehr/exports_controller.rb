# frozen_string_literal: true

module Lakeraven
  module EHR
    class ExportsController < ApplicationController
      # POST /exports
      def create
        export = BulkExport.new(
          id: SecureRandom.uuid,
          export_type: params[:export_type] || "patient",
          status: "pending",
          request_url: request.original_url,
          output_format: "application/fhir+ndjson",
          client_id: current_token&.application&.uid,
          since_timestamp: params[:since],
          type_filters: params[:type]
        )
        export.set_defaults!
        export.requested_types = BulkExport.normalize_types(params[:type])

        self.class.store[export.id] = export
        run_export(export)

        render json: { id: export.id, status: export.status }, status: :accepted,
               content_type: FHIR_CONTENT_TYPE
      end

      # GET /exports/:id
      def show
        export = self.class.store[params[:id]]
        return render_not_found("Export", params[:id]) unless export

        if export.client_id && current_token&.application&.uid != export.client_id
          render_operation_outcome(
            status: :forbidden, severity: "error",
            code: "forbidden", diagnostics: "Export belongs to a different client"
          )
          return
        end

        resp = export.status_response
        if resp[:status] == 202
          resp[:headers]&.each { |k, v| response.headers[k] = v }
          head :accepted
        else
          render json: resp[:body], status: resp[:status], content_type: FHIR_CONTENT_TYPE
        end
      end

      # DELETE /exports/:id
      def destroy
        export = self.class.store.delete(params[:id])
        export ? head(:accepted) : render_not_found("Export", params[:id])
      end

      def self.store
        @store ||= {}
      end

      def self.reset_store!
        @store = {}
      end

      private

      def run_export(export)
        export.start_processing!
        service = EhiExportService.new(patient_dfn: params[:patient_dfn] || "1")
        result = service.export(
          resource_types: export.requested_types,
          since: export.since_timestamp
        )

        files = (result[:files] || []).map do |file|
          {
            "type" => file[:resource_type] || file[:type],
            "url" => export_file_url(export_id: export.id, file_name: file[:file_name]),
            "count" => file[:count] || 0,
            "file_name" => file[:file_name],
            "content" => file[:content]
          }
        end

        export.complete!(files)
      rescue => e
        export.fail!(e.message)
      end
    end
  end
end
