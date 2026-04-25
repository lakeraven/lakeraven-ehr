# frozen_string_literal: true

require "test_helper"
require "ostruct"

module Lakeraven
  module EHR
    class LocationTest < ActiveSupport::TestCase
      # =============================================================================
      # EXISTING TESTS (find_by_ien, persisted?, active?, to_fhir basics)
      # =============================================================================

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

      # -- edge cases ----------------------------------------------------------

      test "find_by_ien returns nil for nil" do
        assert_nil Location.find_by_ien(nil)
      end

      test "find_by_ien returns nil for zero" do
        assert_nil Location.find_by_ien(0)
      end

      test "find_by_ien returns nil for negative" do
        assert_nil Location.find_by_ien(-1)
      end

      test "to_fhir omits alias when no abbreviation" do
        loc = Location.new(ien: 1, name: "Test", abbreviation: nil)
        fhir = loc.to_fhir
        assert_equal [], fhir[:alias]
      end

      test "to_param returns IEN string" do
        loc = Location.new(ien: 42, name: "Test")
        assert_equal "42", loc.to_param
      end

      test "stores type and division" do
        loc = Location.new(ien: 1, name: "Test", type: "clinic", division: "D1")
        assert_equal "clinic", loc.type
        assert_equal "D1", loc.division
      end

      # =============================================================================
      # VALIDATION TESTS (ported from rpms_redux)
      # =============================================================================

      test "should be valid with required attributes" do
        location = Location.new(name: "Test Location", location_type: "site")
        assert location.valid?, "Location should be valid with name and type"
      end

      test "should require name" do
        location = Location.new(location_type: "site")
        refute location.valid?
        assert_includes location.errors[:name], "can't be blank"
      end

      test "should validate location_type if present" do
        location = Location.new(name: "Test", location_type: "invalid")
        refute location.valid?
        assert_includes location.errors[:location_type], "is not included in the list"
      end

      test "should allow blank location_type" do
        location = Location.new(name: "Test")
        assert location.valid?
      end

      test "should validate status if present" do
        location = Location.new(name: "Test", status: "invalid")
        refute location.valid?
        assert_includes location.errors[:status], "is not included in the list"
      end

      test "should default status to active" do
        location = Location.new(name: "Test")
        assert_equal "active", location.status
      end

      test "should validate physical_type if present" do
        location = Location.new(name: "Test", physical_type: "invalid")
        refute location.valid?
        assert_includes location.errors[:physical_type], "is not included in the list"
      end

      test "should validate ien if present and positive" do
        location = Location.new(name: "Test", ien: 0)
        refute location.valid?
        assert_includes location.errors[:ien], "must be greater than 0"

        location.ien = 100
        assert location.valid?
      end

      # =============================================================================
      # STATUS HELPER TESTS (ported from rpms_redux)
      # =============================================================================

      test "active? returns true for active status" do
        location = Location.new(name: "Test", status: "active")
        assert location.active?
        refute location.suspended?
        refute location.inactive?
      end

      test "suspended? returns true for suspended status" do
        location = Location.new(name: "Test", status: "suspended")
        assert location.suspended?
        refute location.active?
        refute location.inactive?
      end

      test "inactive? returns true for inactive status" do
        location = Location.new(name: "Test", status: "inactive")
        assert location.inactive?
        refute location.active?
        refute location.suspended?
      end

      test "available_for_scheduling? returns true only for active locations" do
        location = Location.new(name: "Test", status: "active")
        assert location.available_for_scheduling?

        location.status = "suspended"
        refute location.available_for_scheduling?

        location.status = "inactive"
        refute location.available_for_scheduling?
      end

      # =============================================================================
      # TYPE HELPER TESTS (ported from rpms_redux)
      # =============================================================================

      test "type_display returns human-readable type" do
        location = Location.new(name: "Test", location_type: "site")
        assert_equal "Site", location.type_display

        location.location_type = "building"
        assert_equal "Building", location.type_display

        location.location_type = "room"
        assert_equal "Room", location.type_display

        location.location_type = nil
        assert_equal "Unknown", location.type_display
      end

      test "physical_type_display returns human-readable physical type" do
        location = Location.new(name: "Test", physical_type: "bu")
        assert_equal "Building", location.physical_type_display

        location.physical_type = "ro"
        assert_equal "Room", location.physical_type_display

        location.physical_type = "si"
        assert_equal "Site", location.physical_type_display

        location.physical_type = nil
        assert_equal "Unknown", location.physical_type_display
      end

      # =============================================================================
      # ADDRESS HELPER TESTS (ported from rpms_redux)
      # =============================================================================

      test "full_address combines address parts" do
        location = Location.new(
          name: "Test",
          address_line1: "123 Main St",
          city: "Anchorage",
          state: "AK",
          zip_code: "99501"
        )
        assert_equal "123 Main St, Anchorage, AK, 99501", location.full_address
      end

      test "full_address handles missing parts" do
        location = Location.new(name: "Test", city: "Anchorage", state: "AK")
        assert_equal "Anchorage, AK", location.full_address

        location = Location.new(name: "Test")
        assert_equal "", location.full_address
      end

      # =============================================================================
      # FHIR SERIALIZATION TESTS (ported from rpms_redux, hash-based)
      # =============================================================================

      test "to_fhir includes status" do
        location = Location.new(ien: 100, name: "Test Clinic", status: "active")
        fhir = location.to_fhir

        assert_equal "active", fhir[:status]
      end

      test "to_fhir includes RPMS identifier" do
        location = Location.new(ien: 100, name: "Test")
        fhir = location.to_fhir

        rpms_id = fhir[:identifier].find { |id| id[:system].include?("rpms") }
        assert_not_nil rpms_id
        assert_equal "100", rpms_id[:value]
        assert_equal "usual", rpms_id[:use]
      end

      test "to_fhir includes type coding" do
        location = Location.new(ien: 100, name: "Test", location_type: "site")
        fhir = location.to_fhir

        assert fhir[:type].any?
        type = fhir[:type].first
        coding = type[:coding].first
        assert_equal "site", coding[:code]
        assert_equal "Site", coding[:display]
      end

      test "to_fhir includes physical type" do
        location = Location.new(ien: 100, name: "Test", physical_type: "bu")
        fhir = location.to_fhir

        assert_not_nil fhir[:physicalType]
        coding = fhir[:physicalType][:coding].first
        assert_equal "bu", coding[:code]
        assert_equal "Building", coding[:display]
      end

      test "to_fhir includes address" do
        location = Location.new(
          ien: 100,
          name: "Test",
          address_line1: "123 Main St",
          city: "Anchorage",
          state: "AK",
          zip_code: "99501"
        )
        fhir = location.to_fhir

        assert_not_nil fhir[:address]
        assert_equal "Anchorage", fhir[:address][:city]
        assert_equal "AK", fhir[:address][:state]
        assert_equal "99501", fhir[:address][:postalCode]
      end

      test "to_fhir includes telecom" do
        location = Location.new(ien: 100, name: "Test", phone: "907-555-1234")
        fhir = location.to_fhir

        assert_equal 1, fhir[:telecom].count
        phone = fhir[:telecom].first
        assert_equal "phone", phone[:system]
        assert_equal "907-555-1234", phone[:value]
      end

      test "to_fhir includes managing organization reference" do
        location = Location.new(ien: 100, name: "Test", managing_organization_ien: 50)
        fhir = location.to_fhir

        assert_not_nil fhir[:managingOrganization]
        assert fhir[:managingOrganization][:reference].include?("50")
      end

      test "resource_class returns Location" do
        assert_equal "Location", Location.resource_class
      end

      test "from_fhir_attributes extracts attributes" do
        fhir_resource = OpenStruct.new(
          name: "FHIR Clinic",
          status: "active",
          type: [
            OpenStruct.new(coding: [ OpenStruct.new(code: "site") ])
          ],
          physicalType: OpenStruct.new(
            coding: [ OpenStruct.new(code: "bu") ]
          ),
          managingOrganization: OpenStruct.new(
            reference: "Organization/rpms-organization-100"
          )
        )

        attrs = Location.from_fhir_attributes(fhir_resource)
        assert_equal "FHIR Clinic", attrs[:name]
        assert_equal "active", attrs[:status]
        assert_equal "site", attrs[:location_type]
        assert_equal "bu", attrs[:physical_type]
        assert_equal 100, attrs[:managing_organization_ien]
      end

      test "from_fhir creates location from FHIR resource" do
        fhir_resource = OpenStruct.new(
          name: "External Clinic",
          status: "active",
          type: [],
          physicalType: nil,
          managingOrganization: nil
        )

        location = Location.from_fhir(fhir_resource)
        assert location.is_a?(Location)
        assert_equal "External Clinic", location.name
        assert_equal "active", location.status
      end

      # =============================================================================
      # US CORE / TEFCA COMPLIANCE TESTS (ported from rpms_redux)
      # =============================================================================

      test "location FHIR is US Core compliant" do
        location = Location.new(ien: 100, name: "US Core Compliant Location", status: "active")
        fhir = location.to_fhir

        assert fhir[:name].present?, "US Core requires name"
        assert fhir[:status].present?, "Should have status"
      end

      test "location FHIR can be serialized to JSON" do
        location = Location.new(
          ien: 100,
          name: "JSON Test",
          location_type: "site",
          status: "active"
        )

        json = nil
        assert_nothing_raised do
          json = location.to_fhir.to_json
        end
        parsed = JSON.parse(json)
        assert_equal "Location", parsed["resourceType"]
      end
    end
  end
end
