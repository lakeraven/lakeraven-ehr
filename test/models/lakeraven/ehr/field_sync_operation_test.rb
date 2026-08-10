# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class FieldSyncOperationTest < ActiveSupport::TestCase
      VALID = {
        client_op_id: "op-1", operation_type: "create",
        target_type: "FieldLabTracking", outcome: "applied"
      }.freeze

      test "creates a valid operation" do
        assert FieldSyncOperation.create!(VALID).persisted?
      end

      test "requires a client_op_id" do
        op = FieldSyncOperation.new(VALID.except(:client_op_id))
        refute op.valid?
      end

      test "client_op_id is unique" do
        FieldSyncOperation.create!(VALID)
        dup = FieldSyncOperation.new(VALID)
        refute dup.valid?
        assert dup.errors[:client_op_id].any?
      end

      test "rejects an unknown outcome" do
        op = FieldSyncOperation.new(VALID.merge(outcome: "maybe"))
        refute op.valid?
      end

      test "persists a rejected op with an unknown operation_type for audit" do
        op = FieldSyncOperation.create!(VALID.merge(client_op_id: "op-2", operation_type: "delete", outcome: "rejected"))
        assert op.persisted?
      end

      test "unresolved_conflicts scope filters on outcome and resolved" do
        FieldSyncOperation.create!(VALID.merge(client_op_id: "c1", outcome: "conflict", resolved: false))
        FieldSyncOperation.create!(VALID.merge(client_op_id: "c2", outcome: "conflict", resolved: true))
        FieldSyncOperation.create!(VALID.merge(client_op_id: "a1", outcome: "applied"))

        ids = FieldSyncOperation.unresolved_conflicts.pluck(:client_op_id)
        assert_equal [ "c1" ], ids
      end
    end
  end
end
