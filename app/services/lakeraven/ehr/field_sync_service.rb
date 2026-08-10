# frozen_string_literal: true

module Lakeraven
  module EHR
    # FieldSyncService -- server-authoritative reconciliation of the batch of
    # operations a field iPad captured offline and submits on reconnect (#418,
    # #399, #410).
    #
    # Reconciliation contract (per operation):
    #   applied     — accepted; the server record is authoritative. Returns the
    #                 server id + version the client should now hold.
    #   duplicate   — client_op_id already reconciled (safe replay on flaky
    #                 cellular). The prior outcome is returned unchanged.
    #   conflict    — an update whose base_version no longer matches the server
    #                 record. The server keeps its version and the operation is
    #                 parked (resolved: false) in the reconciliation queue for a
    #                 clinician to resolve. Never silently overwritten.
    #   rejected    — malformed / not-found target. Recorded, not applied.
    #   unsupported — no handler registered for the target_type. Recorded, not
    #                 applied — no silent fallback.
    #
    # Handlers are constructor-injected so tests can supply fakes. A handler
    # implements: create(op) -> record; find(id) -> record|nil;
    # version_of(record) -> Integer; apply(record, op) -> record.
    class FieldSyncService
      # Normalized view of one submitted operation.
      Operation = Struct.new(
        :client_op_id, :operation_type, :target_type, :target_id,
        :base_version, :payload, :client_recorded_at,
        :device_id, :clinician_duz, :site_ien, :batch_id,
        keyword_init: true
      )

      Result = Struct.new(:operations, keyword_init: true) do
        def applied = operations.reject(&:replayed?).select(&:applied?)
        def conflicts = operations.select(&:conflict?)
        def duplicates = operations.select(&:replayed?)

        def fully_reconciled?
          operations.none? { |o| %w[conflict rejected unsupported].include?(o.outcome) }
        end

        def summary
          operations.each_with_object(Hash.new(0)) do |o, h|
            h[o.replayed? ? "duplicate" : o.outcome] += 1
          end
        end
      end

      def initialize(handlers: nil)
        @handlers = handlers || { FieldLabTrackingService::TARGET_TYPE => FieldLabTrackingService.new }
      end

      # operations: Array of hashes (typically parsed JSON from the device).
      # Returns Result wrapping the persisted FieldSyncOperation rows.
      def reconcile(operations:, batch_id: nil, device_id: nil, clinician_duz: nil, site_ien: nil)
        rows = Array(operations).map do |raw|
          op = normalize(raw, batch_id:, device_id:, clinician_duz:, site_ien:)
          reconcile_one(op)
        end

        Result.new(operations: rows)
      end

      private

      def normalize(raw, batch_id:, device_id:, clinician_duz:, site_ien:)
        h = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
        h = h.deep_symbolize_keys

        Operation.new(
          client_op_id: h[:client_op_id],
          operation_type: h[:operation_type],
          target_type: h[:target_type],
          target_id: h[:target_id],
          base_version: h[:base_version],
          payload: (h[:payload] || {}).deep_symbolize_keys,
          client_recorded_at: h[:client_recorded_at],
          device_id: h[:device_id] || device_id,
          clinician_duz: h[:clinician_duz] || clinician_duz,
          site_ien: h[:site_ien] || site_ien,
          batch_id: batch_id
        )
      end

      def reconcile_one(op)
        return reject_missing_key(op) if op.client_op_id.blank?

        existing = FieldSyncOperation.find_by(client_op_id: op.client_op_id)
        if existing # idempotent replay — prior outcome stands, tagged for the response
          existing.replayed = true
          return existing
        end

        handler = @handlers[op.target_type]
        return record(op, outcome: "unsupported", reason: "no handler for target_type #{op.target_type.inspect}") if handler.nil?

        case op.operation_type
        when "create"
          apply_create(op, handler)
        when "update"
          apply_update(op, handler)
        else
          record(op, outcome: "rejected", reason: "unknown operation_type #{op.operation_type.inspect}")
        end
      end

      def apply_create(op, handler)
        rec = handler.create(op)
        record(op, outcome: "applied", server_resource_id: rec.id.to_s, server_version: handler.version_of(rec))
      rescue ActiveRecord::RecordInvalid, ArgumentError => e
        record(op, outcome: "rejected", reason: e.message)
      end

      def apply_update(op, handler)
        rec = handler.find(op.target_id)
        return record(op, outcome: "rejected", reason: "target #{op.target_type}/#{op.target_id} not found") if rec.nil?

        server_version = handler.version_of(rec)
        if op.base_version.present? && op.base_version.to_i != server_version
          return record(
            op, outcome: "conflict", resolved: false,
            server_resource_id: rec.id.to_s, server_version: server_version,
            reason: "base_version #{op.base_version} != server_version #{server_version}"
          )
        end

        handler.apply(rec, op)
        record(op, outcome: "applied", server_resource_id: rec.id.to_s, server_version: handler.version_of(rec))
      rescue ActiveRecord::RecordInvalid, ArgumentError,
             FieldLabTrackingRecord::IllegalTransition, FieldLabTrackingService::UnknownAction => e
        record(op, outcome: "rejected", reason: e.message)
      end

      def reject_missing_key(op)
        # No idempotency key means we cannot dedupe a retry; refuse loudly.
        FieldSyncOperation.new(
          operation_type: op.operation_type.presence || "create",
          target_type: op.target_type.presence || "unknown",
          outcome: "rejected",
          outcome_reason: "missing client_op_id"
        )
      end

      def record(op, outcome:, reason: nil, server_resource_id: nil, server_version: nil, resolved: false)
        FieldSyncOperation.create!(
          client_op_id: op.client_op_id,
          batch_id: op.batch_id,
          device_id: op.device_id,
          clinician_duz: op.clinician_duz,
          site_ien: op.site_ien,
          operation_type: op.operation_type.presence || "create",
          target_type: op.target_type.presence || "unknown",
          target_id: op.target_id,
          base_version: op.base_version,
          payload: op.payload,
          client_recorded_at: op.client_recorded_at,
          outcome: outcome,
          outcome_reason: reason,
          server_resource_id: server_resource_id,
          server_version: server_version,
          resolved: resolved
        )
      end
    end
  end
end
