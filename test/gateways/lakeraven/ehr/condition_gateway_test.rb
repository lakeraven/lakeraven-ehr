# frozen_string_literal: true

require "test_helper"

# Tests for ConditionGateway — engine wrapper around RpmsRpc::Problem.
# Engine vocabulary is "Condition" (matches app/models/lakeraven/ehr/condition.rb);
# rpms-rpc vocabulary is "Problem".
module Lakeraven
  module EHR
    class ConditionGatewayTest < ActiveSupport::TestCase
      # --- read: for_patient ---

      test "for_patient returns the seeded problem list" do
        RpmsRpc.client.seed_keyed_collection(:problem_list, "1", [
          { icd_code: "E11.9", description: "Type 2 diabetes", status: "A" }
        ])

        result = ConditionGateway.for_patient(1)

        assert_kind_of Array, result
        assert_equal "E11.9", result.first[:icd_code]
      end

      # --- write: add / update / delete ---

      test "add returns success with the saved IEN" do
        # rpms-rpc 0.3.0: Problem.add/update write via :problem_set (was :problem_edit).
        RpmsRpc.client.seed_scalar(:problem_set, "1", "55")

        result = ConditionGateway.add(1, { icd_code: "E11.9", description: "Type 2 diabetes" })

        assert result[:success]
        assert_equal 55, result[:ien]
      end

      test "update returns success with the saved IEN" do
        RpmsRpc.client.seed_scalar(:problem_set, "1", "55")

        result = ConditionGateway.update(1, 55, { status: "I" })

        assert result[:success]
        assert_equal 55, result[:ien]
      end

      test "delete issues BGOPROB DEL with the IEN and reason, and returns success" do
        # 0.3.0: delete calls DEL^BGOPROB (:problem_remove), whose success
        # reply is "" — the same value the mock returns for ANY unseeded RPC.
        # Asserting result[:success] alone is therefore vacuous (a regression
        # to another RPC, or to no RPC at all, would ride the default green),
        # so pin the recorded wire call: name and IEN^TYPE^REASON param.
        result = ConditionGateway.delete(1, 55, reason: "Entered in error")

        assert result[:success]
        assert_equal 55, result[:ien]
        call = RpmsRpc.client.received_calls.last
        assert_equal "BGOPROB DEL", call[:rpc]
        assert_equal [ "55^^Entered in error" ], call[:params]
      end

      test "delete surfaces a server error reply as failure" do
        # The mock CAN express this failure: an error reply is "-CODE^text",
        # keyed (like every scalar seed) by the RPC's first param.
        RpmsRpc.client.seed_scalar(:problem_remove, "55^^Entered in error", "-1^Cannot delete")

        result = ConditionGateway.delete(1, 55, reason: "Entered in error")

        refute result[:success]
        assert_nil result[:ien]
      end

      test "add returns failure for invalid dfn" do
        result = ConditionGateway.add(nil, { icd_code: "E11.9" })

        refute result[:success]
      end

      # --- filter ---

      test "filter returns the seeded list scoped by IPL tab" do
        RpmsRpc.client.seed_keyed_collection(:problem_filter, "1", [
          { icd_code: "I10", description: "Essential hypertension", status: "A" }
        ])

        result = ConditionGateway.filter(1, scope: :core)

        assert_kind_of Array, result
        assert_equal "I10", result.first[:icd_code]
      end

      test "filter raises for unknown scope" do
        assert_raises(ArgumentError) { ConditionGateway.filter(1, scope: :unknown_scope) }
      end

      test "filter returns empty for invalid dfn" do
        assert_equal [], ConditionGateway.filter(nil, scope: :core)
      end
    end
  end
end
