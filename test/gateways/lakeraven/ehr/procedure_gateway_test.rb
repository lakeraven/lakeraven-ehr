# frozen_string_literal: true

require "test_helper"

# Tests for ProcedureGateway — read via RpmsRpc::Procedure.for_patient and
# write via RpmsRpc::Procedure.add (lakeraven/rpms-rpc#64).
module Lakeraven
  module EHR
    class ProcedureGatewayTest < ActiveSupport::TestCase
      # --- read: for_patient ---

      test "for_patient returns the patient's procedure list" do
        # One V CPT row as RpmsRpc::Procedure.for_patient returns it: the
        # visit date, and no status (V CPT has none; rpms-rpc #375).
        RpmsStandIn.answer(RpmsRpc::Procedure, :for_patient, 1, with: [
          { ien: "7001", visit_ien: "2090061", date: Date.new(2026, 3, 10), cpt_code: "99213",
            name: "Office visit, established", provider: "MARTINEZ,SARAH" }
        ])

        result = ProcedureGateway.for_patient(1)

        assert_kind_of Array, result
        assert_equal "Office visit, established", result.first[:name]
      end

      # --- write: add ---
      # RpmsRpc::Procedure.add files through BEHOENPC SAVE and reads the V CPT
      # rows before and after (rpms-rpc#712); its live spec proves the filing.
      # Here: what the gateway hands it, and what the gem refuses before any RPC.

      test "add hands the call to RpmsRpc::Procedure.add and returns its answer" do
        with_recording_stub(RpmsRpc::Procedure, :add, { success: true, ien: 42 }) do |calls|
          assert_equal({ success: true, ien: 42 },
            ProcedureGateway.add(1, 2090061, "99213", modifiers: [ "25" ], narrative: "Office visit", quantity: 2))
          assert_equal [ { args: [ "1", "2090061", "99213" ],
                           kwargs: { modifiers: [ "25" ], narrative: "Office visit", quantity: 2 } } ], calls
        end
      end

      test "add returns failure when called with missing arguments" do
        result = ProcedureGateway.add(nil, 2090061, "99213")

        refute result[:success]
        assert_nil result[:ien]
      end
    end
  end
end
