# frozen_string_literal: true

require "test_helper"

# Tests for PovGateway — visit purpose-of-visit (diagnosis) entry.
# Wraps RpmsRpc::Pov (lakeraven/rpms-rpc#63).
module Lakeraven
  module EHR
    class PovGatewayTest < ActiveSupport::TestCase
      class FakePovAPI
        attr_reader :calls

        def initialize(returns:)
          @returns = returns
          @calls = []
        end

        def add(dfn, visit_ien, diagnosis_code, **opts)
          @calls << { dfn:, visit_ien:, diagnosis_code:, opts: }
          @returns
        end
      end

      test "add returns failure shape when no provider is available" do
        result = PovGateway.add(1, 2090061, "J45.909", narrative: "Asthma", via: nil)
        assert_equal({ success: false, ien: nil, raw: nil }, result)
      end

      test "add delegates with identifiers coerced to strings" do
        fake = FakePovAPI.new(returns: { success: true, ien: 42, raw: "42" })

        result = PovGateway.add(1, 2090061, "J45.909",
          narrative: "Asthma",
          modifiers: { primary: true },
          via: fake)

        assert_equal({ success: true, ien: 42, raw: "42" }, result)
        assert_equal 1, fake.calls.length
        call = fake.calls.first
        assert_equal "1", call[:dfn]
        assert_equal "2090061", call[:visit_ien]
        assert_equal "J45.909", call[:diagnosis_code]
        assert_equal "Asthma", call[:opts][:narrative]
        assert_equal({ primary: true }, call[:opts][:modifiers])
      end

      test "default_provider is RpmsRpc::Pov" do
        assert_equal ::RpmsRpc::Pov, PovGateway.default_provider
      end
    end
  end
end
