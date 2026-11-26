# frozen_string_literal: true

require "test_helper"

# Tests for EncounterGateway — patient appointment/encounter data
# (RpmsRpc::Encounter.for_patient, ORWPT APPTLST). The appointments are answered in setup.
module Lakeraven
  module EHR
    class EncounterGatewayTest < ActiveSupport::TestCase
      setup do
        seed_encounter_data
      end

      # === for_patient ===

      test "for_patient returns array of hashes" do
        visits = EncounterGateway.for_patient(1)

        assert visits.is_a?(Array), "Should return array"
      end

      test "for_patient returns seeded encounter data" do
        visits = EncounterGateway.for_patient(1)

        assert visits.length >= 1, "Should find seeded encounters"
      end

      test "for_patient parses appointment fields" do
        visits = EncounterGateway.for_patient(1)
        return skip "No encounters seeded" if visits.empty?

        visit = visits.first
        assert visit.key?(:location), "Visit should have location"
        assert visit.key?(:status), "Visit should have status"
      end

      test "for_patient returns empty for unknown patient" do
        visits = EncounterGateway.for_patient(999999)

        assert visits.is_a?(Array), "Should return array"
        assert_equal 0, visits.length
      end

      private

      def seed_encounter_data
        RpmsStandIn.answer(RpmsRpc::Encounter, :for_patient, 1, with: [
          { datetime: Date.new(2026, 3, 10), location_ien: 1, location: "Primary Care Clinic", status: "KEPT" },
          { datetime: Date.new(2026, 4, 15), location_ien: 1, location: "Primary Care Clinic", status: "SCHEDULED" }
        ])
      end
    end
  end
end
