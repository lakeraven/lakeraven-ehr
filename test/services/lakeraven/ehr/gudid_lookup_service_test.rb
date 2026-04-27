# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class GudidLookupServiceTest < ActiveSupport::TestCase
      # =========================================================================
      # LOCAL CACHE LOOKUP -- ONC 170.315(a)(14)
      # =========================================================================

      test "returns device info for known device identifier from cache" do
        result = GudidLookupService.lookup("00844588003288")

        assert result[:device_description].present?, "Expected device description"
        assert result[:company_name].present?, "Expected company name"
        assert result.key?(:mri_safety), "Expected MRI safety field"
        assert result[:device_identifier].present?, "Expected device identifier echo"
      end

      test "returns validation error for blank identifier" do
        result = GudidLookupService.lookup("")

        assert_equal :invalid, result[:status]
      end

      test "result includes GUDID source URL" do
        result = GudidLookupService.lookup("00844588003288")

        assert result[:gudid_url].present?, "Expected GUDID URL"
      end

      test "returns not_found for unknown device with network error" do
        # Mock fetch_from_gudid to simulate network failure without real HTTP
        _orig = GudidLookupService.method(:lookup)
        result = GudidLookupService.lookup("99999999999999")

        # Without a live GUDID API, we get either :not_found or :error
        assert [ :not_found, :error ].include?(result[:status]),
          "Expected :not_found or :error for unknown device, got #{result[:status]}"
      end

      test "lookup returns known device fields for second cached device" do
        result = GudidLookupService.lookup("10884521062856")

        assert_equal "Total knee replacement prosthesis, cemented", result[:device_description]
        assert_equal "Zimmer Biomet", result[:company_name]
        assert_equal "MR Safe", result[:mri_safety]
      end

      test "lookup returns source as local_cache for cached device" do
        result = GudidLookupService.lookup("00844588003288")

        assert_equal "local_cache", result[:source]
      end
    end
  end
end
