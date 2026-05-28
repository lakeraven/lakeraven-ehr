# frozen_string_literal: true

require "test_helper"

# Tests for CapabilitiesGateway — imaging-access predicate fired on every
# chart open. Wraps RpmsRpc::Capabilities.imaging_user? (lakeraven/rpms-rpc#101).
module Lakeraven
  module EHR
    class CapabilitiesGatewayTest < ActiveSupport::TestCase
      # Test double — captures the adapted user object so we can verify
      # that the gateway converted a plain DUZ string into something the
      # underlying predicate can consume.
      class FakeCapabilitiesAPI
        attr_reader :calls

        def initialize(returns:)
          @returns = returns
          @calls = []
        end

        def imaging_user?(user)
          @calls << user
          @returns
        end
      end

      # --- via: nil (provider unavailable) ---

      test "imaging_user? returns false when no provider is available" do
        refute CapabilitiesGateway.imaging_user?("301", via: nil)
      end

      # --- delegation + adaptation via a fake provider ---

      test "imaging_user? passes a user-shaped object with a string duz" do
        fake = FakeCapabilitiesAPI.new(returns: true)

        assert CapabilitiesGateway.imaging_user?(301, via: fake)

        assert_equal 1, fake.calls.length
        assert_respond_to fake.calls.first, :duz
        assert_equal "301", fake.calls.first.duz
      end

      test "imaging_user? returns whatever the provider returns" do
        refute CapabilitiesGateway.imaging_user?("301", via: FakeCapabilitiesAPI.new(returns: false))
        assert CapabilitiesGateway.imaging_user?("301", via: FakeCapabilitiesAPI.new(returns: true))
      end

      test "imaging_user? short-circuits before dispatching for blank duz" do
        fake = FakeCapabilitiesAPI.new(returns: true)

        refute CapabilitiesGateway.imaging_user?(nil, via: fake)
        refute CapabilitiesGateway.imaging_user?("", via: fake)
        refute CapabilitiesGateway.imaging_user?("   ", via: fake)

        assert_empty fake.calls
      end

      # --- default_provider ---

      test "default_provider returns RpmsRpc::Capabilities when it ships" do
        skip "Requires RpmsRpc::Capabilities.imaging_user? (lakeraven/rpms-rpc#101)" unless
          defined?(::RpmsRpc::Capabilities) && ::RpmsRpc::Capabilities.respond_to?(:imaging_user?)
        assert_equal ::RpmsRpc::Capabilities, CapabilitiesGateway.default_provider
      end

      # --- end-to-end against the real provider ---

      test "imaging_user? caches across calls end-to-end" do
        skip "Requires RpmsRpc::Capabilities.imaging_user? (lakeraven/rpms-rpc#101)" unless
          CapabilitiesGateway.default_provider

        RpmsRpc::Capabilities.clear_imaging_cache!
        RpmsRpc.client.seed_keyed_collection(:imaging_user_keys, "301", [ { key_name: "MAG WINDOWS" } ])

        before = RpmsRpc.client.received_calls.length
        5.times { CapabilitiesGateway.imaging_user?("301") }
        new_calls = RpmsRpc.client.received_calls.length - before

        assert_equal 1, new_calls
      ensure
        RpmsRpc::Capabilities.clear_imaging_cache! if defined?(RpmsRpc::Capabilities)
      end
    end
  end
end
