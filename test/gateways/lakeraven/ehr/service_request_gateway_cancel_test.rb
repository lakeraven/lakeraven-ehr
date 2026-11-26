# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # RCIS has no referral delete: a referral is cancelled by filing its
    # status through BMC REFERRAL STATUS UPDATE (rpms-rpc #380). The old
    # delete sent BMCRPC DELREFRL, which no option on a built image serves.
    class ServiceRequestGatewayCancelTest < ActiveSupport::TestCase
      test "cancel files status X for the referral through BMC REFERRAL STATUS UPDATE" do
        # Nothing answers this first call, so it reaches the connection: what
        # the gateway sends is on its record.
        ServiceRequestGateway.cancel("9001")

        sent = RpmsRpc.client.received_calls.select { |c| c[:rpc] == "BMC REFERRAL STATUS UPDATE" }
        assert_equal [ [ "9001", "X" ] ], sent.map { |c| c[:params] }

        # And when rpms-rpc reports the status filed, the gateway says cancelled.
        RpmsStandIn.answer(RpmsRpc::Referral, :cancel, "9001", with: { success: true, message: "1", raw: "1" })

        result = ServiceRequestGateway.cancel("9001")

        assert result[:success]
        assert_equal "9001", result[:ien]
      end

      test "a refusal from the routine is a failure carrying its message" do
        RpmsStandIn.answer(RpmsRpc::Referral, :cancel, "9002",
          with: { success: false, code: "0", ien: nil, message: "Not a valid Referral Ien", raw: "~`0^Not a valid Referral Ien" })

        result = ServiceRequestGateway.cancel("9002")

        refute result[:success]
        assert_equal "Not a valid Referral Ien", result[:error]
      end

      test "an id that is not a referral IEN fails without reaching the broker" do
        result = ServiceRequestGateway.cancel("SR-DRAFT-001")

        refute result[:success]
        assert_empty RpmsRpc.client.received_calls.select { |c| c[:rpc] == "BMC REFERRAL STATUS UPDATE" }
      end

      test "a broker error is a failure, not a cancellation" do
        RpmsStandIn.answer(RpmsRpc::Referral, :cancel, "9003") { raise RpmsRpc::Client::RpcError, "M ERROR=UPDTSTRF+3^BMCRPC3" }

        result = ServiceRequestGateway.cancel("9003")

        refute result[:success]
        assert_match(/BMCRPC3/, result[:error])
      end
    end
  end
end
