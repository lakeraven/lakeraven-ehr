# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class LocationTest < ActiveSupport::TestCase
      test "find_by_ien returns Location for known IEN" do
        loc = Location.find_by_ien(1)
        assert_not_nil loc
        assert_equal "Primary Care Clinic", loc.name
        assert_equal "PCC", loc.abbreviation
      end

      test "find_by_ien returns nil for unknown IEN" do
        assert_nil Location.find_by_ien(99_999)
      end

      test "persisted? with valid IEN" do
        assert Location.new(ien: 1, name: "Test").persisted?
      end

      test "persisted? false without IEN" do
        refute Location.new(name: "Test").persisted?
      end

      test "active? defaults to true" do
        assert Location.new(ien: 1, name: "Test").active?
      end

      test "to_fhir returns Location resource" do
        loc = Location.find_by_ien(1)
        fhir = loc.to_fhir

        assert_equal "Location", fhir[:resourceType]
        assert_equal "1", fhir[:id]
        assert_equal "Primary Care Clinic", fhir[:name]
      end

      test "to_fhir includes alias for abbreviation" do
        loc = Location.find_by_ien(1)
        fhir = loc.to_fhir

        assert_includes fhir[:alias], "PCC"
      end

      test "to_fhir mode is instance" do
        loc = Location.new(ien: 1, name: "Test")
        assert_equal "instance", loc.to_fhir[:mode]
      end
    end
  end
end
