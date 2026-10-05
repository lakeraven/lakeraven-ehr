# frozen_string_literal: true

require "test_helper"

# Tests for ImmunizationRefusalGateway — records a patient's refusal of
# an immunization on the open encounter. Distinct from ImmunizationGateway
# (read-only).
# Wraps RpmsRpc::ImmunizationRefusal (lakeraven/rpms-rpc#76).
module Lakeraven
  module EHR
    class ImmunizationRefusalGatewayTest < ActiveSupport::TestCase
      include BrokerStubbing

      class FakeRefusalAPI
        attr_reader :calls

        def initialize(returns: {})
          @returns = returns
          @calls = []
        end

        # Same keywords as RpmsRpc::ImmunizationRefusal.record, so a gateway
        # that sends any other keyword raises here as it does on the gem.
        def record(dfn, vaccine_ien, reason_ien:, narrative: nil, refusal_date: nil, provider_duz: nil)
          @calls << { method: :record, args: [ dfn, vaccine_ien ],
                      reason_ien: reason_ien, narrative: narrative }
          @returns[:record] || { success: true, ien: nil, raw: "" }
        end
      end

      # --- via: nil ---

      test "record returns failure shape when no provider is available" do
        result = ImmunizationRefusalGateway.record(1, 42,
          reason_ien: 3, via: nil)

        assert_equal({ success: false, ien: nil, raw: nil }, result)
      end

      # --- delegation ---

      test "record delegates with dfn coerced and the reason IEN passed as reason_ien" do
        fake = FakeRefusalAPI.new(returns: { record: { success: true, ien: nil, raw: "" } })

        result = ImmunizationRefusalGateway.record(1, 42,
          reason_ien: 3, narrative: "Family declines",
          via: fake)

        assert_equal({ success: true, ien: nil, raw: "" }, result)
        assert_equal [ "1", 42 ], fake.calls.first[:args]
        assert_equal 3, fake.calls.first[:reason_ien]
        assert_equal "Family declines", fake.calls.first[:narrative]
      end

      # --- the real gem method (#583) ---
      # No fake API in between: the gateway calls RpmsRpc::ImmunizationRefusal
      # itself, so a keyword the gem does not take raises ArgumentError here.

      test "record through the gem files the reason IEN as piece 8 of BGOREF SET" do
        broker = FakeBroker.new.on("BGOREF SET", "")
        use_broker(broker) do
          result = ImmunizationRefusalGateway.record(1, 42,
            reason_ien: 3, narrative: "Family declines")

          assert result[:success]
          assert_equal "BGOREF SET", broker.last_call[:rpc]
          inp = broker.last_call[:params].first.split("^", -1)
          assert_equal "IMMUNIZATION", inp[1]
          assert_equal "42", inp[2]
          assert_equal "1", inp[3]
          assert_equal "Family declines", inp[5]
          assert_equal "3", inp[7]
        end
      end

      # --- default_provider ---

      test "default_provider resolves to RpmsRpc::ImmunizationRefusal when the gem ships it" do
        provider = ImmunizationRefusalGateway.default_provider
        refute_nil provider, "expected RpmsRpc::ImmunizationRefusal to be loaded via the gateway's guarded require"
        assert_equal "RpmsRpc::ImmunizationRefusal", provider.name
      end
    end
  end
end
