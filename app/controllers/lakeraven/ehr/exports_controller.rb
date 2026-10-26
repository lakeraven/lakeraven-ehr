# frozen_string_literal: true

module Lakeraven
  module EHR
    class ExportsController < ApplicationController
      include PatientCompartment
      include ExportOwnership

      rate_limit only: %i[create show destroy]

      # A bulk export IS a read of the patient's record; it needs read scope as
      # well as write, and it is bound to the compartment.
      # A bulk export dumps the patient's record; EhiExportService::FHIR_RESOURCE_TYPES
      # is what actually lands in the files.
      discloses_clinical_data :create, reads: EhiExportService::FHIR_RESOURCE_TYPES
      compartment_bound :create, param: :patient_dfn
      before_action :authorize_export_owner!, only: %i[show destroy]

      # Shown on the status OperationOutcome. The exception text stays in the log.
      EXPORT_FAILURE_DIAGNOSTIC = "Export failed"

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
        return render_since_unsupported if since_requested?

        # One list for the 400 check and the export. Normalizing again
        # inside BulkExport.normalize_types dropped a stripped name such
        # as " Patient" after this check had already accepted it.
        type_names = BulkExport.type_names(requested_type_param)
        unsupported = unsupported_type_names(type_names)
        return render_unsupported_types(unsupported) if unsupported.any?

        export = BulkExport.new(
          id: SecureRandom.uuid,
          export_type: params[:export_type] || "patient",
          status: "pending",
          request_url: request.original_url,
          output_format: "application/fhir+ndjson",
          client_id: export_owner_identity,
          type_filters: requested_type_param
        )
        export.set_defaults!
        export.requested_types = type_names.nil? ? BulkExport.normalize_types(nil) : type_names

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
        service = EhiExportService.new(
          patient_dfn: params[:patient_dfn].presence || "1",
          resource_types: export.requested_types
        )
        result = service.export
        if result[:success]
          export.complete!(export_output_files(export, result[:files] || []))
        else
          # The diagnostic shown to the caller stays generic. The real
          # reason (unknown patient, a fetch that raised) stays in the log.
          Rails.logger.error("[export] #{Array(result[:errors]).join("; ")}")
          export.fail!(EXPORT_FAILURE_DIAGNOSTIC)
        end
      rescue => e
        Rails.logger.error("[export] #{e.full_message}")
        export.fail!(EXPORT_FAILURE_DIAGNOSTIC)
      end

      # FHIR Bulk Data names these `_since` and `_type`. This route has
      # always read the unprefixed params; accept either spelling.
      def since_requested?
        params[:since].present? || params[:_since].present?
      end

      def requested_type_param
        params[:_type].presence || params[:type]
      end

      def render_since_unsupported
        render_operation_outcome(
          status: :bad_request,
          severity: "error",
          code: "not-supported",
          diagnostics: "The _since parameter is not supported"
        )
      end

      # EhiExportService writes a fixed set of FHIR files. A _type (or the
      # legacy type param) that names anything outside that set used to
      # complete with the type silently dropped. Refuse at kickoff instead.
      # `names` is BulkExport.type_names — nil when the caller sent no filter.
      def unsupported_type_names(names)
        Array(names).reject { |name| EhiExportService::FHIR_RESOURCE_TYPES.include?(name) }
      end

      def render_unsupported_types(names)
        render_operation_outcome(
          status: :bad_request,
          severity: "error",
          code: "not-supported",
          diagnostics: "unsupported resource types: #{names.join(', ')}"
        )
      end

      # EhiExportService emits :name and :type. The download route stores
      # the name as file_name. `type` stays the Bulk Data manifest type
      # (the FHIR resource name when the service set one). `file_type` is
      # the service type the egress check branches on: fhir_ndjson,
      # audit_csv, configuration, or manifest.
      def export_output_files(export, files)
        files.map { |file| export_output_file(export, file) }
      end

      def export_output_file(export, file)
        name = file[:name]
        {
          "type" => file[:resource_type] || file[:type],
          "file_type" => file[:type],
          "url" => export_file_url(export_id: export.id, file_name: name),
          "count" => file[:count] || 0,
          "file_name" => name,
          "content" => file[:content]
        }
      end
    end
  end
end
