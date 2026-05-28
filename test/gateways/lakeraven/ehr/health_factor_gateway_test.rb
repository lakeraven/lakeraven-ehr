# frozen_string_literal: true

require "test_helper"

# Tests for HealthFactorGateway — IHS health-factor (structured observation) entry.
# Wraps RpmsRpc::HealthFactor (lakeraven/rpms-rpc#65).
module Lakeraven
  module EHR
    class HealthFactorGatewayTest < ActiveSupport::TestCase
      class FakeHealthFactorAPI
        attr_reader :calls

        def initialize(returns:)
          @returns = returns
          @calls = []
        end

        def add(dfn, visit_ien, factor_code, **opts)
          @calls << { dfn:, visit_ien:, factor_code:, opts: }
          @returns
        end
      end

      test "add returns failure shape when no provider is available" do
        result = HealthFactorGateway.add(1, 2090061, "TOB-CURRENT", level: "MODERATE", via: nil)
        assert_equal({ success: false, ien: nil, raw: nil }, result)
      end

      test "add delegates with identifiers coerced to strings" do
        fake = FakeHealthFactorAPI.new(returns: { success: true, ien: 17, raw: "17" })

        result = HealthFactorGateway.add(1, 2090061, "TOB-CURRENT",
          level: "MODERATE",
          narrative: "Daily smoker",
          via: fake)

        assert_equal({ success: true, ien: 17, raw: "17" }, result)
        call = fake.calls.first
        assert_equal "1", call[:dfn]
        assert_equal "2090061", call[:visit_ien]
        assert_equal "TOB-CURRENT", call[:factor_code]
        assert_equal "MODERATE", call[:opts][:level]
        assert_equal "Daily smoker", call[:opts][:narrative]
      end

      test "default_provider resolves to RpmsRpc::HealthFactor when the gem ships it" do
        provider = HealthFactorGateway.default_provider
        refute_nil provider, "expected RpmsRpc::HealthFactor to be loaded via the gateway's guarded require"
        assert_equal "RpmsRpc::HealthFactor", provider.name
      end
    end
  end
end
