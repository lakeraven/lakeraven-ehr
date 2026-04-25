# frozen_string_literal: true

require "test_helper"

# Tests for ImmunizationGateway — immunization/allergy list via ORQQAL LIST.
# Note: the EHR ImmunizationGateway currently delegates to allergy_list mapping
# (to be expanded to BIPC IMMLIST when immunization-specific RPCs are wired).
# Uses mock data seeded in test_helper.rb.
module Lakeraven
  module EHR
    class ImmunizationGatewayTest < ActiveSupport::TestCase
      setup do
        seed_immunization_data
      end

      # === for_patient ===

      test "for_patient returns array" do
        results = ImmunizationGateway.for_patient(1)

        assert results.is_a?(Array), "Should return array"
      end

      test "for_patient returns seeded data" do
        results = ImmunizationGateway.for_patient(1)

        assert results.length >= 1, "Should find seeded immunization/allergy data"
      end

      test "for_patient parses allergy fields" do
        results = ImmunizationGateway.for_patient(1)
        return skip "No data seeded" if results.empty?

        entry = results.first
        assert entry.key?(:allergen), "Entry should have allergen"
      end

      test "for_patient returns empty for unknown patient" do
        results = ImmunizationGateway.for_patient(999999)

        assert results.is_a?(Array), "Should return array"
        assert_equal 0, results.length
      end

      private

      def seed_immunization_data
        RpmsRpc.client.seed_keyed_collection(:allergy_list, "1", [
          { allergen: "PENICILLIN", reaction: "RASH", severity: "MODERATE" },
          { allergen: "ASPIRIN", reaction: "HIVES", severity: "MILD" }
        ])
      end
    end
  end
end
