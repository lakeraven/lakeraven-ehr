# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class OrganizationTest < ActiveSupport::TestCase
      test "find_by_ien returns Organization for known IEN" do
        org = Organization.find_by_ien(1)
        assert_not_nil org
        assert_equal "Alaska Native Medical Center", org.name
        assert_equal "463", org.station_number
      end

      test "find_by_ien returns nil for unknown IEN" do
        assert_nil Organization.find_by_ien(99_999)
      end

      test "persisted? with valid IEN" do
        assert Organization.new(ien: 1, name: "Test").persisted?
      end

      test "persisted? false without IEN" do
        refute Organization.new(name: "Test").persisted?
      end

      test "full_address combines parts" do
        org = Organization.new(address: "123 Main St", city: "Anchorage", state: "AK", zip_code: "99508")
        assert_equal "123 Main St, Anchorage, AK, 99508", org.full_address
      end

      test "full_address handles missing parts" do
        org = Organization.new(city: "Anchorage", state: "AK")
        assert_equal "Anchorage, AK", org.full_address
      end

      test "to_fhir returns Organization resource" do
        org = Organization.find_by_ien(1)
        fhir = org.to_fhir

        assert_equal "Organization", fhir[:resourceType]
        assert_equal "1", fhir[:id]
        assert_equal "Alaska Native Medical Center", fhir[:name]
      end

      test "to_fhir includes address" do
        org = Organization.find_by_ien(1)
        fhir = org.to_fhir

        addr = fhir[:address]&.first
        assert_equal "AK", addr[:state]
      end

      test "to_fhir includes telecom" do
        org = Organization.find_by_ien(1)
        fhir = org.to_fhir

        assert fhir[:telecom]&.any?
      end

      test "to_fhir includes station number as identifier" do
        org = Organization.find_by_ien(1)
        fhir = org.to_fhir

        assert fhir[:identifier]&.any?
      end
    end
  end
end
