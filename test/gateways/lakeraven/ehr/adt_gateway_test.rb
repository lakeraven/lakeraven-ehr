# frozen_string_literal: true

require "test_helper"

# BPRM twin — ADT movement gateway tests (scenario #15).
#
# The write path is BLOCKED: the #8994 dump (rpms-rpc#171) has no stock
# movement-WRITE RPC, so admit/transfer/discharge/cancel return a 501 blocked
# result and never call the broker. The confirmed ORWPT movement reads
# (ADMITLST/INPLOC) go through the gem's RpmsRpc::Adt wrapper.
module Lakeraven
  module EHR
    class AdtGatewayTest < ActiveSupport::TestCase
      include BrokerStubbing

      # --- Blocked write path (no stock movement-write RPC) ----------------

      test "admit is blocked and never calls the broker" do
        broker = FakeBroker.new
        use_broker(broker) do
          result = AdtGateway.admit(42, 3, at: "2026-08-20 14:00", provider: "BEGAY,MICHELLE")

          refute result[:success]
          assert_equal 501, result[:status]
          assert_equal :admission, result[:kind]
          assert_match(/no stock/i, result[:error])
          assert_empty broker.calls
        end
      end

      test "the blocked admit echoes the attempted movement for the audit trail" do
        broker = FakeBroker.new
        use_broker(broker) do
          result = AdtGateway.admit(42, 3, at: "2026-08-20 14:00", provider: "BEGAY,MICHELLE")

          assert_equal 42, result[:attempted][:dfn]
          assert_equal 3, result[:attempted][:ward_ien]
        end
      end

      test "transfer is blocked and never calls the broker" do
        broker = FakeBroker.new
        use_broker(broker) do
          result = AdtGateway.transfer(42, 4, at: "2026-08-21 08:00")

          refute result[:success]
          assert_equal 501, result[:status]
          assert_equal :transfer, result[:kind]
          assert_empty broker.calls
        end
      end

      test "discharge is blocked and never calls the broker" do
        broker = FakeBroker.new
        use_broker(broker) do
          result = AdtGateway.discharge(42, at: "2026-08-23 11:00", disposition: "Home")

          refute result[:success]
          assert_equal 501, result[:status]
          assert_equal :discharge, result[:kind]
          assert_empty broker.calls
        end
      end

      test "cancel movement is blocked and never calls the broker" do
        broker = FakeBroker.new
        use_broker(broker) do
          result = AdtGateway.cancel_movement(8001)

          refute result[:success]
          assert_equal 501, result[:status]
          assert_equal :cancel, result[:kind]
          assert_empty broker.calls
        end
      end

      # --- Confirmed read path (ORWPT ADMITLST / INPLOC via the gem) -------

      test "admissions lists a patient's movements via ORWPT ADMITLST" do
        broker = FakeBroker.new.on("ORWPT ADMITLST", [
          "3260820.1400^3^2 EAST^1^8001^",
          "3260610.0900^4^ICU^1^7900^"
        ])
        use_broker(broker) do
          result = AdtGateway.admissions(42)

          assert result[:success]
          assert_equal 200, result[:status]
          assert_equal 2, result[:admissions].length
          assert_equal 3, result[:admissions].first[:location_ien]
          assert_equal "2 EAST", result[:admissions].first[:location]
          assert_equal "ORWPT ADMITLST", broker.last_call[:rpc]
        end
      end

      test "current location returns the ward when the patient is admitted" do
        broker = FakeBroker.new.on("ORWPT INPLOC", "3^2 EAST^2E")
        use_broker(broker) do
          result = AdtGateway.current_location(42)

          assert result[:success]
          assert result[:admitted]
          assert_equal 3, result[:current_location][:location_ien]
          assert_equal "ORWPT INPLOC", broker.last_call[:rpc]
        end
      end

      test "current location reports not-admitted when the RPC returns a leading zero" do
        broker = FakeBroker.new.on("ORWPT INPLOC", "0^^")
        use_broker(broker) do
          result = AdtGateway.current_location(42)

          assert result[:success]
          refute result[:admitted]
          assert_nil result[:current_location]
        end
      end

      test "admissions validates the dfn before calling the broker" do
        broker = FakeBroker.new
        use_broker(broker) do
          result = AdtGateway.admissions(nil)

          refute result[:success]
          assert_equal 422, result[:status]
          assert_empty broker.calls
        end
      end

      test "a read with a broker-unreachable condition returns 503" do
        broker = FakeBroker.new.raise_with(RpmsRpc::Client::ConnectionError.new("refused"))
        use_broker(broker) do
          result = AdtGateway.admissions(42)

          assert_equal 503, result[:status]
          assert_equal "ADT service unavailable", result[:error]
        end
      end
    end
  end
end
