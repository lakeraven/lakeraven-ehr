# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class LocationGatewayTest < ActiveSupport::TestCase
      test "find returns location data for known IEN" do
        loc = LocationGateway.find(1)

        refute_nil loc, "Should find seeded location"
        name = loc.respond_to?(:name) ? loc.name : loc[:name]
        assert_equal "Primary Care Clinic", name
      end

      test "find returns nil for non-existent location" do
        loc = LocationGateway.find(999_999)

        assert_nil loc
      end

      test "find returns nil for blank IEN" do
        assert_nil LocationGateway.find(nil)
        assert_nil LocationGateway.find("")
      end
    end
  end
end
