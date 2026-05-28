# frozen_string_literal: true

require "test_helper"

# Tests for CapabilitiesGateway — imaging-access predicate fired on every
# chart open. Wraps RpmsRpc::Capabilities.imaging_user? (lakeraven/rpms-rpc#101).
module Lakeraven
  module EHR
    class CapabilitiesGatewayTest < ActiveSupport::TestCase
      setup do
        RpmsRpc::Capabilities.clear_imaging_cache!
        RpmsRpc.client.seed_keyed_collection(:imaging_user_keys, "301", [
          { key_name: "MAG WINDOWS" }
        ])
        RpmsRpc.client.seed_keyed_collection(:imaging_user_keys, "999", [])
      end

      teardown do
        RpmsRpc::Capabilities.clear_imaging_cache!
      end

      test "imaging_user? is true when the user holds any MAG key" do
        assert CapabilitiesGateway.imaging_user?("301")
      end

      test "imaging_user? is false when the user holds no MAG keys" do
        refute CapabilitiesGateway.imaging_user?("999")
      end

      test "imaging_user? coerces integer duz to string" do
        assert CapabilitiesGateway.imaging_user?(301)
      end

      test "imaging_user? is false for blank or invalid duz" do
        refute CapabilitiesGateway.imaging_user?(nil)
        refute CapabilitiesGateway.imaging_user?("")
        refute CapabilitiesGateway.imaging_user?("   ")
      end

      test "imaging_user? caches so repeated chart opens hit the RPC once" do
        before = RpmsRpc.client.received_calls.count { |c| c[:rpc] == "MAGGUSERKEYS" }
        5.times { CapabilitiesGateway.imaging_user?("301") }
        after = RpmsRpc.client.received_calls.count { |c| c[:rpc] == "MAGGUSERKEYS" }

        assert_equal 1, after - before
      end
    end
  end
end
