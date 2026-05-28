# frozen_string_literal: true

require "test_helper"

# Tests for ImmunizationRefusalGateway — records a patient's refusal of
# an immunization on the open encounter. Distinct from ImmunizationGateway
# (read-only).
# Wraps RpmsRpc::ImmunizationRefusal (lakeraven/rpms-rpc#76).
module Lakeraven
  module EHR
    class ImmunizationRefusalGatewayTest < ActiveSupport::TestCase
      class FakeRefusalAPI
        attr_reader :calls

        def initialize(returns: {})
          @returns = returns
          @calls = []
        end

        def record(dfn, vaccine_code, reason_code:, narrative: nil)
          @calls << { method: :record, args: [ dfn, vaccine_code ],
                      reason_code: reason_code, narrative: narrative }
          @returns[:record] || { success: true, ien: 1, raw: "1" }
        end
      end

      # --- via: nil ---

      test "record returns failure shape when no provider is available" do
        result = ImmunizationRefusalGateway.record(1, "MMR",
          reason_code: :parental, via: nil)

        assert_equal({ success: false, ien: nil, raw: nil }, result)
      end

      # --- delegation ---

      test "record delegates with dfn coerced and reason_code symbol passed through" do
        fake = FakeRefusalAPI.new(returns: { record: { success: true, ien: 17, raw: "17" } })

        result = ImmunizationRefusalGateway.record(1, "MMR",
          reason_code: :religious, narrative: "Family declines",
          via: fake)

        assert_equal({ success: true, ien: 17, raw: "17" }, result)
        assert_equal [ "1", "MMR" ], fake.calls.first[:args]
        assert_equal :religious, fake.calls.first[:reason_code]
        assert_equal "Family declines", fake.calls.first[:narrative]
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
