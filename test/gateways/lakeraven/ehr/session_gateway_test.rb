# frozen_string_literal: true

require "test_helper"

# Tests for SessionGateway — the cold-launch bootstrap that resolves a user
# DUZ to the client-config root, registry hints, and default division IEN.
# Wraps RpmsRpc::Session (lakeraven/rpms-rpc#99).
module Lakeraven
  module EHR
    class SessionGatewayTest < ActiveSupport::TestCase
      CONFIG_ROOT = 'c:\\CEHRTT15\\lib\\'

      setup do
        RpmsRpc.client.seed_scalar(:session_default_source, "CIAVM DEFAULT SOURCE", CONFIG_ROOT)
        RpmsRpc.client.seed(:session_registry, "", { root: 'HKLM\\Software\\IHS\\CIAVM' })
        RpmsRpc.client.seed(:session_vim_info, "301", {
          site_ien: 539,
          site_name: "TEST SERVICE UNIT",
          user_name: "PROVIDER,TEST"
        })
      end

      test "bootstrap returns the documented hash shape" do
        result = SessionGateway.bootstrap("301")

        assert_equal CONFIG_ROOT, result[:config_root]
        assert_equal 539, result[:default_site_ien]
        assert_equal "TEST SERVICE UNIT", result[:vim_info][:site_name]
      end

      test "bootstrap coerces integer duz to string before delegating" do
        result = SessionGateway.bootstrap(301)

        assert_equal 539, result[:default_site_ien]
      end

      test "bootstrap returns nil for a blank or invalid duz" do
        assert_nil SessionGateway.bootstrap(nil)
        assert_nil SessionGateway.bootstrap("")
        assert_nil SessionGateway.bootstrap("0")
      end
    end
  end
end
