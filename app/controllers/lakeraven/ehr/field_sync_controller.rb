# frozen_string_literal: true

module Lakeraven
  module EHR
    # FieldSyncController -- reconnect endpoint for street-medicine field iPads
    # (#418). Accepts a batch of operations captured offline and returns the
    # server-authoritative outcome for each, plus a work queue of unresolved
    # conflicts and clinical follow-ups.
    #
    # This is a device/operations surface, not a FHIR read surface, so it emits
    # plain JSON and enforces a write-capable scope rather than the per-resource
    # read scope the FHIR controllers use.
    class FieldSyncController < ApplicationController
      # POST /field/sync
      def sync
        permitted = params.permit!.to_h.deep_symbolize_keys
        operations = Array(permitted[:operations])
        single_site = authorized_site_iens.one? ? authorized_site_iens.first : nil

        result = FieldSyncService.new.reconcile(
          operations: operations,
          batch_id: permitted[:batch_id],
          device_id: permitted[:device_id],
          # Identity is token-derived, never caller-supplied.
          clinician_duz: token_duz,
          site_ien: single_site,
          authorized_sites: authorized_site_iens,
          all_sites: all_sites_token?
        )

        render json: {
          batch_id: permitted[:batch_id],
          summary: result.summary,
          operations: result.operations.map { |op| serialize_operation(op) }
        }, status: :ok
      end

      # GET /field/work_queue
      def work_queue
        requested = params[:site_ien].presence
        sites = resolve_query_sites(requested)
        return if performed? # resolve_query_sites rendered a 403

        conflicts = FieldSyncOperation.unresolved_conflicts.for_sites(sites)
        follow_ups = FieldLabTrackingService.new.work_queue(
          site_iens: sites, patient_ref: params[:patient_ref]
        )

        render json: {
          conflicts: conflicts.order(created_at: :asc).map { |op| serialize_conflict(op) },
          follow_ups: follow_ups
        }, status: :ok
      end

      private

      # The set of site IENs this request may read. Never returns "all sites":
      # a caller must either be scoped to explicit sites or name a site the token
      # authorizes. Renders 403 and returns nil when nothing is authorized.
      def resolve_query_sites(requested)
        if requested
          unless all_sites_token? || authorized_site_iens.include?(requested)
            render_forbidden("Token is not authorized for site #{requested}")
            return nil
          end
          return [ requested ]
        end

        return authorized_site_iens if authorized_site_iens.any?

        render_forbidden("A site_ien is required for this token")
        nil
      end

      # Field sync writes clinical data — require a write/wildcard scope in a
      # user or system context. Overrides the parent's per-FHIR-resource read
      # check (which does not apply to this operations endpoint).
      def authorize_fhir_scope!
        writable = token_scopes.any? { |s| s.match?(%r{\A(user|system)/.*\.(\*|write|c?ruds?)\z}) }
        return if writable

        render_forbidden("Field sync requires a user/ or system/ write scope")
      end

      def token_scopes
        current_token&.scopes.to_s.split
      end

      # Site IENs the token is explicitly scoped to, via the Lakeraven field
      # extension scope `site/<ien>`. These bound both reads and writes.
      def authorized_site_iens
        @authorized_site_iens ||=
          token_scopes.filter_map { |s| s[%r{\Asite/(\S+)\z}, 1] }
      end

      # A wildcard backend token (system/*.* or system/*.write) may act across
      # sites, but must still name the site it is querying (see resolve_query_sites).
      def all_sites_token?
        token_scopes.any? { |s| s.match?(%r{\Asystem/\*\.(\*|write|c?ruds?)\z}) }
      end

      def token_duz
        current_token&.resource_owner_id&.to_s
      end

      def serialize_operation(op)
        {
          client_op_id: op.client_op_id,
          # The real persisted outcome is always reported; a replay is flagged
          # separately so an unresolved conflict/rejection isn't masked as a
          # successful "duplicate".
          outcome: op.outcome,
          duplicate: op.replayed? ? true : nil,
          server_resource_id: op.server_resource_id,
          server_version: op.server_version,
          reason: op.outcome_reason
        }.compact
      end

      def serialize_conflict(op)
        {
          client_op_id: op.client_op_id,
          target_type: op.target_type,
          target_id: op.target_id,
          base_version: op.base_version,
          server_version: op.server_version,
          reason: op.outcome_reason,
          recorded_at: op.client_recorded_at
        }.compact
      end
    end
  end
end
