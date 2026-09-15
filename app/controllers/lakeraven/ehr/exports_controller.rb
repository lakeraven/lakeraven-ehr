# frozen_string_literal: true

module Lakeraven
  module EHR
    class ExportsController < ApplicationController
      include PatientCompartment
      include ExportOwnership

      # A bulk export IS a read of the patient's record; it needs read scope as
      # well as write, and it is bound to the compartment.
      # A bulk export dumps the patient's record; EhiExportService::FHIR_RESOURCE_TYPES
      # is what actually lands in the files.
      discloses_clinical_data :create, reads: EhiExportService::FHIR_RESOURCE_TYPES
      compartment_bound :create, param: :patient_dfn
      before_action :authorize_export_owner!, only: %i[show destroy]

      # POST /exports
      #
      # A bulk export is a WRITE (it creates a job and materialises a record
      # dump), and this was the one state-changing route with no scope gate: a
      # `system/*.read` token could POST /exports and bulk-export a chart.
      # #501 supersedes this with discloses_clinical_data (read of the
      # disclosed types AND write) plus compartment binding — this gate exists
      # so THIS branch is safe standing alone. Placed on the action rather than
      # at the class top so it does not collide with #501's authorization
      # block when the two branches merge.
      before_action :authorize_fhir_write_scope!, only: :create
      def create
        export = BulkExport.new(
          id: SecureRandom.uuid,
          export_type: params[:export_type] || "patient",
          status: "pending",
          request_url: request.original_url,
          output_format: "application/fhir+ndjson",
          client_id: export_owner_identity,
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

      def stored_export = self.class.store[params[:id]]

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
