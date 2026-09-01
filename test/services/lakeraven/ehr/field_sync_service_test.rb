# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class FieldSyncServiceTest < ActiveSupport::TestCase
      setup { @service = FieldSyncService.new }

      def create_op(client_op_id:, **payload)
        {
          client_op_id: client_op_id, operation_type: "create", target_type: "FieldLabTracking",
          payload: { patient_ref: "panel-1", condition: "HCV", screening_result: "reactive" }.merge(payload)
        }
      end

      test "applies a create operation and returns server id + version" do
        result = @service.reconcile(operations: [ create_op(client_op_id: "op-a") ], batch_id: "b1")

        op = result.operations.first
        assert_equal "applied", op.outcome
        assert op.server_resource_id.present?
        assert_equal 1, op.server_version
        assert_equal 1, FieldLabTrackingRecord.count
      end

      test "idempotent replay does not double-apply" do
        @service.reconcile(operations: [ create_op(client_op_id: "op-b") ])
        result = @service.reconcile(operations: [ create_op(client_op_id: "op-b") ])

        op = result.operations.first
        assert op.replayed?, "replayed op should be tagged"
        assert_equal "applied", op.outcome, "the original persisted outcome is preserved"
        assert_equal 1, result.summary["duplicate"]
        assert_equal 1, FieldLabTrackingRecord.count
        assert_equal 1, FieldSyncOperation.count
      end

      test "an update with a stale base_version is a server-authoritative conflict" do
        created = @service.reconcile(operations: [ create_op(client_op_id: "op-c") ]).operations.first
        id = created.server_resource_id

        # Server advances to version 2 out-of-band (another sync / clinician).
        @service.reconcile(operations: [ update_op("op-d", id, base_version: 1, action: "order_confirmation", confirmation_loinc: "13955-0") ])

        # A second device still holds base_version 1 and tries to advance again.
        result = @service.reconcile(operations: [ update_op("op-e", id, base_version: 1, action: "record_confirmation_result", confirmation_result_status: "positive") ])
        op = result.operations.first

        assert_equal "conflict", op.outcome
        assert_equal 2, op.server_version
        refute op.resolved
        # Server state was NOT overwritten by the stale operation.
        assert_equal "confirmation_ordered", FieldLabTrackingRecord.find(id).stage
      end

      test "a fresh-base update applies and bumps the version" do
        created = @service.reconcile(operations: [ create_op(client_op_id: "op-f") ]).operations.first
        id = created.server_resource_id

        result = @service.reconcile(operations: [ update_op("op-g", id, base_version: 1, action: "order_confirmation", confirmation_loinc: "13955-0") ])
        op = result.operations.first

        assert_equal "applied", op.outcome
        assert_equal 2, op.server_version
        assert_equal "confirmation_ordered", FieldLabTrackingRecord.find(id).stage
      end

      test "unknown target_type is unsupported, never silently applied" do
        result = @service.reconcile(operations: [
          { client_op_id: "op-h", operation_type: "create", target_type: "Wearable", payload: {} }
        ])
        op = result.operations.first
        assert_equal "unsupported", op.outcome
        assert_match(/no handler/, op.outcome_reason)
      end

      test "update to a missing target is rejected" do
        result = @service.reconcile(operations: [ update_op("op-i", "999999", base_version: 1, action: "order_confirmation") ])
        assert_equal "rejected", result.operations.first.outcome
      end

      test "an illegal clinical transition is rejected, not applied" do
        created = @service.reconcile(operations: [ create_op(client_op_id: "op-j") ]).operations.first
        id = created.server_resource_id
        # Recording a result before ordering is illegal.
        result = @service.reconcile(operations: [ update_op("op-k", id, base_version: 1, action: "record_confirmation_result", confirmation_result_status: "positive") ])
        assert_equal "rejected", result.operations.first.outcome
      end

      test "missing client_op_id is rejected and not persisted" do
        result = @service.reconcile(operations: [ { operation_type: "create", target_type: "FieldLabTracking", payload: {} } ])
        op = result.operations.first
        assert_equal "rejected", op.outcome
        refute op.persisted?
      end

      test "concurrent same client_op_id never double-applies and never raises" do
        # First request claims the ledger, applies the clinical record.
        first = @service.reconcile(operations: [ create_op(client_op_id: "race-1") ]).operations.first
        assert_equal "applied", first.outcome
        assert_equal 1, FieldLabTrackingRecord.count

        # Simulate a second in-flight request that passed the find_by dedupe
        # before the first committed: force the lookup to miss so it proceeds to
        # the unique-index claim insert, which must be caught as a replay — not a
        # 500 and not a second clinical mutation.
        result = nil
        with_find_by_miss(FieldSyncOperation) do
          assert_nothing_raised do
            result = @service.reconcile(operations: [ create_op(client_op_id: "race-1") ])
          end
        end

        op = result.operations.first
        assert op.replayed?, "the losing racer must be reported as a replay"
        assert_equal "applied", op.outcome
        assert_equal 1, FieldLabTrackingRecord.count, "no double clinical apply"
        assert_equal 1, FieldSyncOperation.count, "no duplicate ledger row"
      end

      test "an update without base_version is rejected, never blindly applied" do
        created = @service.reconcile(operations: [ create_op(client_op_id: "nb-1") ]).operations.first
        id = created.server_resource_id

        result = @service.reconcile(operations: [
          { client_op_id: "nb-2", operation_type: "update", target_type: "FieldLabTracking",
            target_id: id, payload: { action: "order_confirmation", confirmation_loinc: "13955-0" } }
        ])
        op = result.operations.first
        assert_equal "rejected", op.outcome
        assert_match(/base_version/, op.outcome_reason)
        assert_equal "screened", FieldLabTrackingRecord.find(id).stage
      end

      test "a create with no screening_result is rejected, not silently applied" do
        result = @service.reconcile(operations: [
          { client_op_id: "inc-1", operation_type: "create", target_type: "FieldLabTracking",
            payload: { patient_ref: "panel-1", condition: "HCV" } }
        ])
        assert_equal "rejected", result.operations.first.outcome
        assert_equal 0, FieldLabTrackingRecord.count
      end

      test "replaying a rejected op preserves the original outcome" do
        op = { client_op_id: "rj-1", operation_type: "delete", target_type: "FieldLabTracking", payload: {} }
        @service.reconcile(operations: [ op ])
        result = @service.reconcile(operations: [ op ])

        replayed = result.operations.first
        assert replayed.replayed?
        assert_equal "rejected", replayed.outcome, "a replayed rejection stays rejected, not duplicate"
      end

      test "an op targeting an unauthorized site is rejected" do
        result = @service.reconcile(
          operations: [ create_op(client_op_id: "site-1", site_ien: "999") ],
          authorized_sites: %w[463 500]
        )
        op = result.operations.first
        assert_equal "rejected", op.outcome
        assert_match(/site/i, op.outcome_reason)
        assert_equal 0, FieldLabTrackingRecord.count
      end

      test "cross-site IDOR: an update to a record at an unauthorized site is rejected" do
        # A record that physically belongs to site 999.
        created = @service.reconcile(
          operations: [ create_op(client_op_id: "idor-1", site_ien: "999") ],
          authorized_sites: %w[999]
        ).operations.first
        id = created.server_resource_id

        # A token authorized ONLY for site 463 tries to edit it, laundering the
        # op through an authorized site_ien of its own.
        result = @service.reconcile(
          operations: [
            { client_op_id: "idor-2", operation_type: "update", target_type: "FieldLabTracking",
              target_id: id, base_version: 1, site_ien: "463",
              payload: { action: "order_confirmation", confirmation_loinc: "13955-0" } }
          ],
          authorized_sites: %w[463]
        )
        op = result.operations.first
        assert_equal "rejected", op.outcome
        assert_match(/site/i, op.outcome_reason)
        # The record's clinical state was NOT changed by the cross-site editor.
        assert_equal "screened", FieldLabTrackingRecord.find(id).stage
      end

      test "a replay is authorized against the persisted op's site, not leaked cross-site" do
        @service.reconcile(
          operations: [ create_op(client_op_id: "rep-1", site_ien: "999") ],
          authorized_sites: %w[999]
        )

        # A different token (site 463) that guessed the client_op_id replays it.
        result = @service.reconcile(
          operations: [ create_op(client_op_id: "rep-1", site_ien: "999") ],
          authorized_sites: %w[463]
        )
        op = result.operations.first
        assert_equal "rejected", op.outcome
        refute op.replayed?, "an unauthorized replay must not be reported as a duplicate"
        assert_nil op.server_resource_id, "the persisted resource id must not leak"
      end

      test "a wildcard token cannot create a site-less clinical record" do
        result = @service.reconcile(
          operations: [ create_op(client_op_id: "ws-1") ], # no site_ien
          authorized_sites: [], all_sites: true
        )
        op = result.operations.first
        assert_equal "rejected", op.outcome
        assert_match(/site/i, op.outcome_reason)
        assert_equal 0, FieldLabTrackingRecord.count
      end

      test "a wildcard token with a concrete site still applies" do
        result = @service.reconcile(
          operations: [ create_op(client_op_id: "ws-2", site_ien: "463") ],
          authorized_sites: [], all_sites: true
        )
        assert_equal "applied", result.operations.first.outcome
        assert_equal "463", FieldLabTrackingRecord.last.site_ien
      end

      test "malformed operations are rejected per-op without failing the batch" do
        result = @service.reconcile(operations: [
          "not-an-object",
          [ "also", "bad" ],
          nil,
          { client_op_id: "bad-payload", operation_type: "create",
            target_type: "FieldLabTracking", payload: "nope" },
          create_op(client_op_id: "good-1")
        ])
        outcomes = result.operations.map(&:outcome)
        assert_equal 4, outcomes.count("rejected")
        assert_equal 1, outcomes.count("applied")
        assert_equal "applied", result.operations.last.outcome
        assert_equal 1, FieldLabTrackingRecord.count
      end

      test "result summary counts outcomes across a mixed batch" do
        result = @service.reconcile(operations: [
          create_op(client_op_id: "m1"),
          { client_op_id: "m2", operation_type: "create", target_type: "Wearable", payload: {} }
        ])
        assert_equal 1, result.summary["applied"]
        assert_equal 1, result.summary["unsupported"]
        refute result.fully_reconciled?
      end

      private

      # Force <model>.find_by to miss so a second concurrent request proceeds
      # past the dedupe check to the unique-index claim insert (minitest 6 has
      # no stub helper, so this restores the inherited method on teardown).
      def with_find_by_miss(model)
        model.define_singleton_method(:find_by) { |*_args, **_kwargs| nil }
        yield
      ensure
        model.singleton_class.send(:remove_method, :find_by)
      end

      def update_op(client_op_id, target_id, base_version:, **payload)
        {
          client_op_id: client_op_id, operation_type: "update",
          target_type: "FieldLabTracking", target_id: target_id, base_version: base_version,
          payload: payload
        }
      end
    end
  end
end
