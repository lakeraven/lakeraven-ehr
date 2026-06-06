# frozen_string_literal: true

require "test_helper"

# Tests for SiteGateway — division (site) listing, current-division lookup,
# and division selection. Wraps RpmsRpc::Site (lakeraven/rpms-rpc#100).
module Lakeraven
  module EHR
    class SiteGatewayTest < ActiveSupport::TestCase
      # Test double for the underlying RpmsRpc::Site module.
      class FakeSiteAPI
        attr_reader :select_calls

        def initialize(list: [], current: nil)
          @list = list
          @current = current
          @select_calls = []
        end

        def list(_duz)
          @list
        end

        def current(_duz)
          @current
        end

        def select(duz, site_ien)
          @select_calls << [ duz, site_ien ]
          true
        end
      end

      # --- via: nil (provider unavailable) ---

      test "list returns empty when no provider is available" do
        assert_equal [], SiteGateway.list("301", via: nil)
      end

      test "current returns nil when no provider is available" do
        assert_nil SiteGateway.current("301", via: nil)
      end

      test "select returns false when no provider is available" do
        refute SiteGateway.select("301", 540, via: nil)
      end

      # --- delegation + coercion via a fake provider ---

      test "list delegates to the provider with duz coerced to a string" do
        sites = [ { ien: 539, name: "TSU", current: true } ]
        fake = FakeSiteAPI.new(list: sites)

        assert_equal sites, SiteGateway.list(301, via: fake)
      end

      test "current delegates to the provider with duz coerced to a string" do
        site = { ien: 539, name: "TSU", current: true }
        fake = FakeSiteAPI.new(current: site)

        assert_equal site, SiteGateway.current(301, via: fake)
      end

      test "select delegates with duz and site_ien coerced to strings" do
        fake = FakeSiteAPI.new

        SiteGateway.select(301, 540, via: fake)

        assert_equal [ [ "301", "540" ] ], fake.select_calls
      end

      # --- default_provider ---

      test "default_provider returns RpmsRpc::Site when it ships" do
        skip "Requires RpmsRpc::Site (lakeraven/rpms-rpc#100)" unless
          defined?(::RpmsRpc::Site) && ::RpmsRpc::Site.respond_to?(:list)
        assert_equal ::RpmsRpc::Site, SiteGateway.default_provider
      end

      # --- end-to-end against the real provider ---

      test "list returns the seeded divisions end-to-end" do
        skip "le-lnd: pending lakeraven-ehr catch-up with rpms-rpc PR #121/#122/#124 mapping fixes"
        skip "Requires RpmsRpc::Site (lakeraven/rpms-rpc#100)" unless SiteGateway.default_provider

        RpmsRpc.client.seed_keyed_collection(:site_info, "301", [
          { ien: 539, name: "TEST SERVICE UNIT", abbreviation: "TSU", current: true },
          { ien: 540, name: "TEST CLINIC A", abbreviation: "TCA", current: false }
        ])

        sites = SiteGateway.list("301")

        assert_equal [ 539, 540 ], sites.map { |s| s[:ien] }
      end
    end
  end
end
