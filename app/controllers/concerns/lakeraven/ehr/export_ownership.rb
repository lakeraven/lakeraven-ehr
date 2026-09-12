# frozen_string_literal: true

module Lakeraven
  module EHR
    # Ownership for bulk exports — on EVERY endpoint that touches one.
    #
    # A bulk export is a file of one patient's whole record sitting on disk
    # under a UUID. Three endpoints reach it, and until now only one of them
    # asked who was asking:
    #
    #   GET    /exports/:id                    status — guarded
    #   GET    /exports/:id/files/:file_name    THE ACTUAL BYTES — unguarded
    #   DELETE /exports/:id                     destruction — unguarded
    #
    # Reproduced: `GET /exports/vic-1` refused with 403 while
    # `GET /exports/vic-1/files/PatientNdjson` returned the NDJSON with the
    # SSN in it, and DELETE removed another client's export outright. Guarding
    # the status endpoint and not the content endpoint is not a control; it is
    # a sign on the wrong door.
    #
    # The earlier round-2 hardening was right about identity and wrong about
    # coverage: it keyed ownership on the DUZ instead of the shared browser
    # application (correct) and applied it in one place (not).
    module ExportOwnership
      extend ActiveSupport::Concern

      private

      # WHO owns an export.
      #
      # `application.uid` alone is not an owner: every browser session shares
      # ONE Doorkeeper application, so one clinician's uid compares equal to
      # every other clinician's. A session-derived token names its clinician
      # (DUZ); a system token has no human behind it and the application IS
      # the client.
      def export_owner_identity
        current_duz.presence || current_token&.application&.uid
      end

      def owns_export?(export)
        return true if export.client_id.blank?

        export.client_id == export_owner_identity
      end

      # Refuse before the export's existence is revealed, so these endpoints
      # are not an existence oracle for other clients' export ids either.
      def authorize_export_owner!
        export = find_owned_export
        return render_not_found("Export", export_id_param) if export.nil?
        return if owns_export?(export)

        render_operation_outcome(
          status: :forbidden, severity: "error",
          code: "forbidden", diagnostics: "Export belongs to a different client"
        )
      end

      def export_id_param
        params[:export_id] || params[:id]
      end

      def find_owned_export
        ExportsController.store[export_id_param]
      end
    end
  end
end
