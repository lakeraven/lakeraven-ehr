# frozen_string_literal: true

require "test_helper"

# Tests for ServiceRequestGateway — referral search via BMCRPC SRCHREF.
# The gateway currently only exposes for_patient (returns raw hashes
# from the DataMapper). Tests verify shape and mock data round-trip.
module Lakeraven
  module EHR
    class ServiceRequestGatewayTest < ActiveSupport::TestCase
      setup do
        # Seed referral data for patient DFN 1
        @referrals_seeded = seed_referral_data
      end

      # === for_patient ===

      test "for_patient returns array of hashes" do
        results = ServiceRequestGateway.for_patient(1)

        assert results.is_a?(Array), "Should return array"
      end

      test "for_patient returns seeded referral data" do
        results = ServiceRequestGateway.for_patient(1)

        assert results.length >= 1, "Should find seeded referrals"
      end

      test "for_patient returns empty for unknown patient" do
        results = ServiceRequestGateway.for_patient(999999)

        assert results.is_a?(Array), "Should return array"
        assert_equal 0, results.length, "Should return empty for non-existent patient"
      end

      private

      def seed_referral_data
        # Seed referral search results via the mock client
        RpmsRpc.client.seed_keyed_collection(:referral_search, "1", [
          { ien: "1001", patient_dfn: 1, status: "active", type: "C",
            date: Date.new(2026, 1, 15), provider: "MARTINEZ,SARAH" },
          { ien: "1002", patient_dfn: 1, status: "completed", type: "N",
            date: Date.new(2025, 11, 1), provider: "CHEN,JAMES" }
        ])
      end
    end
  end
end
