# frozen_string_literal: true

require "test_helper"

# Tests for SessionGateway — the cold-launch bootstrap that resolves a user
# DUZ to the client-config root, registry hints, and default division IEN.
# Wraps RpmsRpc::Session (lakeraven/rpms-rpc#99).
module Lakeraven
  module EHR
    class SessionGatewayTest < ActiveSupport::TestCase
      # Test double captures calls so we can prove delegation + coercion.
      class FakeSessionAPI
        attr_reader :calls

        def initialize(returns)
          @returns = returns
          @calls = []
        end

        def bootstrap(duz)
          @calls << duz
          @returns
        end
      end

      test "bootstrap returns nil when no provider is available" do
        assert_nil SessionGateway.bootstrap("301", via: nil)
      end

      test "bootstrap delegates and coerces duz to a string" do
        payload = { config_root: 'c:\\CEHRTT15\\lib\\', default_site_ien: 539, vim_info: {}, registry: {} }
        fake = FakeSessionAPI.new(payload)

        result = SessionGateway.bootstrap(301, via: fake)

        assert_equal payload, result
        assert_equal [ "301" ], fake.calls
      end

      test "default_provider returns RpmsRpc::Session when it ships" do
        skip "Requires RpmsRpc::Session.bootstrap (lakeraven/rpms-rpc#99)" unless
          defined?(::RpmsRpc::Session) && ::RpmsRpc::Session.respond_to?(:bootstrap)
        assert_equal ::RpmsRpc::Session, SessionGateway.default_provider
      end

      # End-to-end: when the real provider is in place, the gateway should
      # surface the documented hash shape without exposing wire details.
      test "bootstrap returns the documented hash shape end-to-end" do
        skip "Requires RpmsRpc::Session.bootstrap (lakeraven/rpms-rpc#99)" unless
          SessionGateway.default_provider

        RpmsRpc.client.seed_scalar(:session_default_source, "CIAVM DEFAULT SOURCE", 'c:\\CEHRTT15\\lib\\')
        RpmsRpc.client.seed(:session_registry, "", { root: 'HKLM\\Software\\IHS\\CIAVM' })
        RpmsRpc.client.seed(:session_vim_info, "301", {
          site_ien: 539, site_name: "TEST SERVICE UNIT", user_name: "PROVIDER,TEST"
        })

        result = SessionGateway.bootstrap("301")

        assert_equal 'c:\\CEHRTT15\\lib\\', result[:config_root]
        assert_equal 539, result[:default_site_ien]
      end
    end
  end
end
