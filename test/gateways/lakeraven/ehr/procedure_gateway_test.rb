# frozen_string_literal: true

require "test_helper"

# Tests for ProcedureGateway — read via RpmsRpc::Procedure.for_patient and
# write via RpmsRpc::Procedure.add (lakeraven/rpms-rpc#64).
module Lakeraven
  module EHR
    class ProcedureGatewayTest < ActiveSupport::TestCase
      # --- read: for_patient ---

      test "for_patient returns the seeded procedure list" do
        # BGOVCPT GET rows: the visit date as MM/DD/YYYY, and no status (V CPT
        # has none; rpms-rpc #375).
        RpmsRpc.client.seed_keyed_collection(:procedure_list, "1", [
          { ien: 7001, visit_ien: 2090061, date: "03/10/2026", cpt_code: "99213",
            name: "Office visit, established", provider: "MARTINEZ,SARAH" }
        ])

        result = ProcedureGateway.for_patient(1)

        assert_kind_of Array, result
        assert_equal "Office visit, established", result.first[:name]
      end

      # --- write: add ---

      test "add returns success with the saved IEN when the RPC returns an IEN" do
        RpmsRpc.client.seed_scalar(:procedure_save, "1", "42")

        result = ProcedureGateway.add(1, 2090061, "99213",
          modifiers: [ "25" ], narrative: "Office visit", quantity: 1)

        assert result[:success]
        assert_equal 42, result[:ien]
      end

      test "add returns failure when called with missing arguments" do
        result = ProcedureGateway.add(nil, 2090061, "99213")

        refute result[:success]
        assert_nil result[:ien]
      end

      test "add coerces integer identifiers to strings" do
        RpmsRpc.client.seed_scalar(:procedure_save, "1", "99")

        result = ProcedureGateway.add(1, 2090061, "99213")

        assert result[:success]
        assert_equal 99, result[:ien]
      end
    end
  end
end
