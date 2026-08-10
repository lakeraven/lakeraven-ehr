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
      # Raised when the idempotency claim loses to a concurrent request holding
      # the same client_op_id (caught as a duplicate replay, never a 500).
      class DuplicateClaim < StandardError; end

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
      #
      # clinician_duz / site_ien are the TOKEN-derived identity the controller
      # resolved; they take precedence over anything in the operation payload so
      # a device cannot attribute a clinical write to an arbitrary clinician/site.
      # authorized_sites (when non-nil) restricts writes to those site IENs;
      # all_sites bypasses that list for a wildcard backend token.
      #
      # Returns Result wrapping the persisted FieldSyncOperation rows.
      def reconcile(operations:, batch_id: nil, device_id: nil, clinician_duz: nil,
                    site_ien: nil, authorized_sites: nil, all_sites: false)
        @authorized_sites = authorized_sites
        @all_sites = all_sites

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
        payload = (h[:payload] || {}).deep_symbolize_keys

        Operation.new(
          client_op_id: h[:client_op_id],
          operation_type: h[:operation_type],
          target_type: h[:target_type],
          target_id: h[:target_id],
          base_version: h[:base_version],
          payload: payload,
          client_recorded_at: h[:client_recorded_at],
          device_id: h[:device_id] || device_id,
          # Token identity wins over payload/op-level values (falls back to the
          # payload only when the token carries none, e.g. a system backend token).
          clinician_duz: clinician_duz.presence || h[:clinician_duz] || payload[:clinician_duz],
          site_ien: site_ien.presence || h[:site_ien] || payload[:site_ien],
          batch_id: batch_id
        )
      end

      def reconcile_one(op)
        return reject_missing_key(op) if op.client_op_id.blank?

        existing = FieldSyncOperation.find_by(client_op_id: op.client_op_id)
        return replay(existing) if existing

        claim_and_reconcile(op)
      rescue ActiveRecord::RecordNotUnique, DuplicateClaim
        # A concurrent request with the same client_op_id claimed the ledger row
        # first. The clinical mutation in this racer rolled back with its claim;
        # return the winner's outcome as an idempotent replay — never a 500,
        # never a second apply. (RecordNotUnique = simultaneous DB race;
        # DuplicateClaim = the uniqueness validation caught an already-committed
        # winner.)
        replay(FieldSyncOperation.where(client_op_id: op.client_op_id).first!)
      end

      # Claim the idempotency key (ledger row) BEFORE the clinical mutation, in a
      # savepoint so a lost race rolls the whole thing back. The unique
      # client_op_id index (plus the model validation) serializes duplicates.
      def claim_and_reconcile(op)
        FieldSyncOperation.transaction(requires_new: true) do
          row = claim(op)
          finalize(row, op)
          row
        end
      end

      def claim(op)
        FieldSyncOperation.create!(claim_attributes(op))
      rescue ActiveRecord::RecordInvalid => e
        raise DuplicateClaim if e.record.errors.of_kind?(:client_op_id, :taken)

        raise
      end

      def finalize(row, op)
        handler = @handlers[op.target_type]
        return finish(row, outcome: "unsupported", reason: "no handler for target_type #{op.target_type.inspect}") if handler.nil?

        unless site_authorized?(op)
          return finish(row, outcome: "rejected", reason: "site #{op.site_ien.inspect} is not authorized for this token")
        end

        case op.operation_type
        when "create"
          apply_create(row, op, handler)
        when "update"
          apply_update(row, op, handler)
        else
          finish(row, outcome: "rejected", reason: "unknown operation_type #{op.operation_type.inspect}")
        end
      end

      def apply_create(row, op, handler)
        rec = handler.create(op)
        finish(row, outcome: "applied", server_resource_id: rec.id.to_s, server_version: handler.version_of(rec))
      rescue ActiveRecord::RecordInvalid, ArgumentError => e
        finish(row, outcome: "rejected", reason: e.message)
      end

      def apply_update(row, op, handler)
        return finish(row, outcome: "rejected", reason: "base_version is required for an update") if op.base_version.blank?

        rec = handler.find(op.target_id)
        return finish(row, outcome: "rejected", reason: "target #{op.target_type}/#{op.target_id} not found") if rec.nil?

        # Lock the clinical row so the version compare-and-apply is atomic: two
        # concurrent fresh-base updates can't both pass the check and both apply.
        rec.with_lock do
          server_version = handler.version_of(rec)
          if op.base_version.to_i != server_version
            return finish(
              row, outcome: "conflict", resolved: false,
              server_resource_id: rec.id.to_s, server_version: server_version,
              reason: "base_version #{op.base_version} != server_version #{server_version}"
            )
          end

          handler.apply(rec, op)
          finish(row, outcome: "applied", server_resource_id: rec.id.to_s, server_version: handler.version_of(rec))
        end
      rescue ActiveRecord::RecordInvalid, ArgumentError,
             FieldLabTrackingRecord::IllegalTransition, FieldLabTrackingService::UnknownAction => e
        finish(row, outcome: "rejected", reason: e.message)
      end

      def replay(row)
        row.replayed = true
        row
      end

      # Site enforcement is off unless the controller supplied an authorized set.
      def site_authorized?(op)
        return true if @authorized_sites.nil? || @all_sites

        op.site_ien.present? && @authorized_sites.map(&:to_s).include?(op.site_ien.to_s)
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

      def claim_attributes(op)
        {
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
          outcome: "pending"
        }
      end

      def finish(row, outcome:, reason: nil, server_resource_id: nil, server_version: nil, resolved: false)
        row.update!(
          outcome: outcome,
          outcome_reason: reason,
          server_resource_id: server_resource_id,
          server_version: server_version,
          resolved: resolved
        )
        row
      end
    end
  end
end
