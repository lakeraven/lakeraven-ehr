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

        result = FieldSyncService.new.reconcile(
          operations: operations,
          batch_id: permitted[:batch_id],
          device_id: permitted[:device_id],
          clinician_duz: permitted[:clinician_duz] || token_duz,
          site_ien: permitted[:site_ien]
        )

        render json: {
          batch_id: permitted[:batch_id],
          summary: result.summary,
          operations: result.operations.map { |op| serialize_operation(op) }
        }, status: :ok
      end

      # GET /field/work_queue
      def work_queue
        site_ien = params[:site_ien]

        conflicts = FieldSyncOperation.unresolved_conflicts
        conflicts = conflicts.for_site(site_ien) if site_ien.present?

        follow_ups = FieldLabTrackingService.new.work_queue(
          site_ien: site_ien, patient_ref: params[:patient_ref]
        )

        render json: {
          conflicts: conflicts.order(created_at: :asc).map { |op| serialize_conflict(op) },
          follow_ups: follow_ups
        }, status: :ok
      end

      private

      # Field sync writes clinical data — require a write/wildcard scope in a
      # user or system context. Overrides the parent's per-FHIR-resource read
      # check (which does not apply to this operations endpoint).
      def authorize_fhir_scope!
        scopes = current_token&.scopes.to_s.split
        writable = scopes.any? { |s| s.match?(%r{\A(user|system)/.*\.(\*|write|c?ruds?)\z}) || s.end_with?("/*.*") }
        return if writable

        render_forbidden("Field sync requires a user/ or system/ write scope")
      end

      def token_duz
        current_token&.resource_owner_id&.to_s
      end

      def serialize_operation(op)
        {
          client_op_id: op.client_op_id,
          outcome: op.replayed? ? "duplicate" : op.outcome,
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
