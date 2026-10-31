# frozen_string_literal: true

require "test_helper"
require "rpms_rpc/client"

module Lakeraven
  module EHR
    # Characterization of how a gateway reaches its backend client today
    # (#646): RpcSupport.broker is the one accessor, it hands out the client
    # rpms-rpc is configured with, audited, and it follows a client swap.
    # These pin the behaviour the backend registry must keep with `rpms`
    # configured.
    class RpcSupportBrokerTest < ActiveSupport::TestCase
      include BrokerStubbing

      setup do
        AuditEvent.delete_all
        AuditContext.reset
      end

      teardown { AuditContext.reset }

      test "the broker sends a gateway's call to the configured client and returns its answer" do
        fake = FakeBroker.new.on("ORWPT ID INFO", "1^ok")

        result = use_broker(fake) { RpcSupport.broker.call_rpc("ORWPT ID INFO", "7") }

        assert_equal "1^ok", result
        assert_equal [ { rpc: "ORWPT ID INFO", params: [ "7" ] } ], fake.calls
      end

      test "the broker handed out is the audited wrapper around the configured client" do
        fake = FakeBroker.new

        use_broker(fake) do
          broker = RpcSupport.broker

          assert_kind_of AuditedBroker, broker
          assert_equal "fake-broker.test", broker.hostname
        end
      end

      test "the broker follows the configured client when it is swapped mid-run" do
        first = FakeBroker.new.on("ORWPT ID INFO", "first")
        second = FakeBroker.new.on("ORWPT ID INFO", "second")

        use_broker(first) { assert_equal "first", RpcSupport.broker.call_rpc("ORWPT ID INFO") }
        use_broker(second) { assert_equal "second", RpcSupport.broker.call_rpc("ORWPT ID INFO") }

        assert_equal 1, first.calls.size
        assert_equal 1, second.calls.size
      end

      test "an unreachable configured client is a 503, never a success" do
        fake = FakeBroker.new.raise_with(RpmsRpc::Client::ConnectionError.new("broker unreachable"))

        result = use_broker(fake) do
          RpcSupport.with_broker("RPMS is unavailable") { RpcSupport.broker.call_rpc("ORWPT ID INFO") }
        end

        assert_equal({ success: false, status: 503, error: "RPMS is unavailable" }, result)
      end

      test "a read goes to the configured client" do
        fake = FakeBroker.new.on("ORWPT APPTLST", [])

        use_broker(fake) { RpcSupport.broker.call_rpc("ORWPT APPTLST", "42") }

        assert_equal [ "42" ], fake.calls_for("ORWPT APPTLST").first&.dig(:params)
      end
    end
  end
end
