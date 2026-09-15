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
      # NOTE: `current_duz` is defined by the session-bridge work (#486) and is
      # NOT on this branch. Until that lands, `respond_to?` is false here and a
      # session-derived token has no clinician identity to compare. That must
      # fail CLOSED (see `owns_export?`), never fall back to the shared
      # application uid — falling back is precisely the defect this concern
      # exists to fix.
      def export_owner_identity
        duz = respond_to?(:current_duz, true) ? current_duz.presence : nil
        duz || current_token&.application&.uid
      end

      # Is the identity we can offer actually capable of naming an owner?
      #
      # A DUZ-shaped client_id means the export was created by a human whose
      # clinician identity we must match. If we cannot resolve one — because
      # #486 has not landed, or because a session token arrived without a DUZ
      # — we cannot answer the ownership question, and an unanswerable
      # authorization question is a refusal.
      def export_owner_identity_resolvable?(export)
        return true unless duz_shaped?(export.client_id)

        respond_to?(:current_duz, true) && current_duz.present?
      end

      def duz_shaped?(client_id)
        client_id.to_s.match?(/\A\d+\z/)
      end

      def owns_export?(export)
        return true if export.client_id.blank?
        return false unless export_owner_identity_resolvable?(export)

        export.client_id == export_owner_identity
      end

      # An export that is not yours is indistinguishable on the wire from one
      # that does not exist.
      #
      # This previously answered 404 for missing and 403 for existing-but-not-
      # yours, which IS an existence oracle — while carrying a comment claiming
      # it was not. Exploitability is low (ids are UUIDs), but a comment
      # asserting the opposite is worse than the oracle: it gets trusted later.
      #
      # Both now answer 404. The distinction survives in the log, where an
      # operator can act on it and an attacker cannot see it — which is how
      # "we could not determine" stays distinguishable from "we determined no"
      # without putting the answer on the wire.
      def authorize_export_owner!
        export = find_owned_export
        return if export && owns_export?(export)

        if export
          Rails.logger.info(
            "[export] refusing #{export_id_param}: owned by another client"
          )
        end
        render_not_found("Export", export_id_param)
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
