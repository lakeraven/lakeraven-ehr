# frozen_string_literal: true

module Lakeraven
  module EHR
    # Resolved-resource authorization for bulk exports: an export — its
    # status, its cancellation, and every file it produced — belongs to the
    # client that requested it. Enforced for EVERY token (not only org-bound
    # ones) by comparing the requesting token's application uid to the
    # export's recorded client_id. Tokens minted without an application
    # (test fixtures) compare as nil and therefore only match exports that
    # were created the same way.
    module ExportClientOwnership
      private

      def authorize_export_client!(export)
        return true if current_token&.application&.uid == export.client_id

        render_operation_outcome(
          status: :forbidden, severity: "error",
          code: "forbidden", diagnostics: "Export belongs to a different client"
        )
        false
      end
    end
  end
end
