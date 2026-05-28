# frozen_string_literal: true

require "test_helper"

# Tests for SiteGateway — division (site) listing, current-division lookup,
# and division selection. Wraps RpmsRpc::Site (lakeraven/rpms-rpc#100).
module Lakeraven
  module EHR
    class SiteGatewayTest < ActiveSupport::TestCase
      setup do
        RpmsRpc.client.seed_keyed_collection(:site_info, "301", [
          { ien: 539, name: "TEST SERVICE UNIT", abbreviation: "TSU", current: true },
          { ien: 540, name: "TEST CLINIC A", abbreviation: "TCA", current: false }
        ])
      end

      test "list returns every division the user can access" do
        sites = SiteGateway.list("301")

        assert_equal [ 539, 540 ], sites.map { |s| s[:ien] }
      end

      test "list coerces integer duz to string" do
        sites = SiteGateway.list(301)

        assert_equal 2, sites.length
      end

      test "list returns empty for blank or invalid duz" do
        assert_equal [], SiteGateway.list(nil)
        assert_equal [], SiteGateway.list("")
        assert_equal [], SiteGateway.list("0")
      end

      test "current returns the flagged division" do
        site = SiteGateway.current("301")

        assert_equal 539, site[:ien]
      end

      test "current returns nil when no division is flagged" do
        RpmsRpc.client.seed_keyed_collection(:site_info, "999", [
          { ien: 539, name: "TSU", current: false }
        ])

        assert_nil SiteGateway.current("999")
      end

      test "select dispatches duz and site_ien as strings" do
        SiteGateway.select(301, 540)

        call = RpmsRpc.client.received_calls.find do |c|
          c[:rpc] == "BEHOSICX SITEINFO" && c[:params].length == 2
        end
        refute_nil call
        assert_equal [ "301", "540" ], call[:params]
      end

      test "select returns false for invalid arguments" do
        refute SiteGateway.select(nil, 540)
        refute SiteGateway.select("301", nil)
        refute SiteGateway.select("301", 0)
      end
    end
  end
end
