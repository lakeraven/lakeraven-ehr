# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class PractitionerTest < ActiveSupport::TestCase
      # MockGatewayAdapter seeds practitioners IEN 101-102.

      # -- find_by_ien -----------------------------------------------------------

      test "find_by_ien returns a Practitioner for a known IEN" do
        prac = Lakeraven::EHR::Practitioner.find_by_ien(101)
        assert_not_nil prac
        assert_kind_of Lakeraven::EHR::Practitioner, prac
        assert_equal 101, prac.ien
        assert_equal "MARTINEZ,SARAH", prac.name
        assert_equal "Cardiology", prac.specialty
        assert_equal "1234567890", prac.npi
        assert_equal "Physician", prac.provider_class
      end

      test "find_by_ien returns nil for unknown IEN" do
        assert_nil Lakeraven::EHR::Practitioner.find_by_ien(99_999)
      end

      test "find_by_ien returns nil for nil" do
        assert_nil Lakeraven::EHR::Practitioner.find_by_ien(nil)
      end

      # -- search ----------------------------------------------------------------

      test "search returns practitioners matching name pattern" do
        results = Lakeraven::EHR::Practitioner.search("MARTINEZ")
        assert_equal 1, results.length
        assert_equal "MARTINEZ,SARAH", results.first.name
      end

      test "search with empty string returns all practitioners" do
        results = Lakeraven::EHR::Practitioner.search("")
        assert_equal 2, results.length
      end

      test "search returns empty array for no matches" do
        assert_equal [], Lakeraven::EHR::Practitioner.search("ZZZZNONEXISTENT")
      end

      # -- composite fields ------------------------------------------------------

      test "name syncs to first_name and last_name" do
        prac = Lakeraven::EHR::Practitioner.new(name: "CHEN,JAMES")
        assert_equal "Chen", prac.last_name
        assert_equal "James", prac.first_name
      end

      # -- display_name ----------------------------------------------------------

      test "display_name formats MUMPS name for display" do
        prac = Lakeraven::EHR::Practitioner.new(name: "MARTINEZ,SARAH")
        assert_equal "SARAH MARTINEZ", prac.display_name
      end

      # -- to_fhir ---------------------------------------------------------------

      test "to_fhir returns a FHIR Practitioner hash" do
        prac = Lakeraven::EHR::Practitioner.find_by_ien(101)
        fhir = prac.to_fhir

        assert_equal "Practitioner", fhir[:resourceType]
        assert_equal "101", fhir[:id]
        assert_equal "MARTINEZ", fhir[:name].first[:family]
        npi_id = fhir[:identifier].find { |id| id[:system]&.include?("npi") }
        assert_equal "1234567890", npi_id[:value]
      end
    end
  end
end
