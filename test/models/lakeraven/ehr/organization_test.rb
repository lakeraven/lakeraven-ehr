# frozen_string_literal: true

require "test_helper"
require "ostruct"

module Lakeraven
  module EHR
    class OrganizationTest < ActiveSupport::TestCase
      # =============================================================================
      # VALIDATION TESTS
      # =============================================================================

      test "should be valid with required attributes" do
        org = Organization.new(name: "Test Organization", org_type: "prov")
        assert org.valid?, "Organization should be valid with name and type"
      end

      test "should require name" do
        org = Organization.new(org_type: "prov")
        refute org.valid?
        assert_includes org.errors[:name], "can't be blank"
      end

      test "should validate org_type if present" do
        org = Organization.new(name: "Test", org_type: "invalid")
        refute org.valid?
        assert_includes org.errors[:org_type], "is not included in the list"
      end

      test "should allow blank org_type" do
        org = Organization.new(name: "Test")
        assert org.valid?
      end

      test "should validate NPI length if present" do
        org = Organization.new(name: "Test", npi: "12345")
        refute org.valid?
        assert org.errors[:npi].any?

        org.npi = "1234567890"
        assert org.valid?
      end

      test "should allow blank NPI" do
        org = Organization.new(name: "Test")
        assert org.valid?
      end

      test "should validate ien if present and positive" do
        org = Organization.new(name: "Test", ien: 0)
        refute org.valid?
        assert_includes org.errors[:ien], "must be greater than 0"

        org.ien = 100
        assert org.valid?
      end

      # =============================================================================
      # TYPE HELPER TESTS
      # =============================================================================

      test "type_display returns human-readable type" do
        org = Organization.new(name: "Test", org_type: "prov")
        assert_equal "Healthcare Provider", org.type_display

        org.org_type = "pay"
        assert_equal "Payer", org.type_display

        org.org_type = "govt"
        assert_equal "Government", org.type_display

        org.org_type = nil
        assert_equal "Unknown", org.type_display
      end

      test "provider? returns true for prov type" do
        org = Organization.new(name: "Test", org_type: "prov")
        assert org.provider?
        refute org.payer?
        refute org.government?
      end

      test "payer? returns true for pay type" do
        org = Organization.new(name: "Test", org_type: "pay")
        assert org.payer?
        refute org.provider?
      end

      test "government? returns true for govt type" do
        org = Organization.new(name: "Test", org_type: "govt")
        assert org.government?
        refute org.provider?
      end

      # =============================================================================
      # FIND / PERSISTENCE TESTS (existing)
      # =============================================================================

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

      # =============================================================================
      # ADDRESS HELPER TESTS (existing)
      # =============================================================================

      test "full_address combines parts" do
        org = Organization.new(address: "123 Main St", city: "Anchorage", state: "AK", zip_code: "99508")
        assert_equal "123 Main St, Anchorage, AK, 99508", org.full_address
      end

      test "full_address handles missing parts" do
        org = Organization.new(city: "Anchorage", state: "AK")
        assert_equal "Anchorage, AK", org.full_address
      end

      test "full_address with all parts" do
        org = Organization.new(address: "4315 Diplomacy Dr", city: "Anchorage", state: "AK", zip_code: "99508")
        assert_equal "4315 Diplomacy Dr, Anchorage, AK, 99508", org.full_address
      end

      test "full_address with only city and state" do
        org = Organization.new(city: "Fairbanks", state: "AK")
        assert_equal "Fairbanks, AK", org.full_address
      end

      test "full_address with no parts" do
        org = Organization.new
        assert_equal "", org.full_address
      end

      # =============================================================================
      # FHIR SERIALIZATION TESTS (existing)
      # =============================================================================

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

      test "to_fhir for organization without address" do
        org = Organization.new(ien: 99, name: "Minimal Org")
        fhir = org.to_fhir
        assert_equal "Organization", fhir[:resourceType]
        assert_equal "Minimal Org", fhir[:name]
      end

      # =============================================================================
      # FHIR SERIALIZATION TESTS (new)
      # =============================================================================

      test "to_fhir includes NPI identifier" do
        org = Organization.new(ien: 100, name: "Test", npi: "1234567890")
        fhir = org.to_fhir

        npi_id = fhir[:identifier].find { |id| id[:system]&.include?("npi") }
        assert_not_nil npi_id
        assert_equal "1234567890", npi_id[:value]
        assert_equal "official", npi_id[:use]
      end

      test "to_fhir includes IEN identifier" do
        org = Organization.new(ien: 100, name: "Test")
        fhir = org.to_fhir

        ien_id = fhir[:identifier].find { |id| id[:system]&.include?("rpms") || id[:system]&.include?("ihs") }
        assert_not_nil ien_id
        assert_equal "100", ien_id[:value]
      end

      test "to_fhir includes tax_id identifier" do
        org = Organization.new(ien: 100, name: "Test", tax_id: "92-1234567")
        fhir = org.to_fhir

        tax_id = fhir[:identifier].find { |id| id[:value] == "92-1234567" }
        assert_not_nil tax_id
      end

      test "to_fhir includes type coding" do
        org = Organization.new(ien: 100, name: "Test", org_type: "prov")
        fhir = org.to_fhir

        assert fhir[:type]&.any?
        type = fhir[:type].first
        coding = type[:coding].first
        assert_equal "prov", coding[:code]
        assert_equal "Healthcare Provider", coding[:display]
        assert_equal "http://terminology.hl7.org/CodeSystem/organization-type", coding[:system]
      end

      test "to_fhir includes partOf reference for parent" do
        org = Organization.new(ien: 100, name: "Child Org", parent_organization_ien: 50)
        fhir = org.to_fhir

        assert_not_nil fhir[:partOf]
        assert fhir[:partOf][:reference].include?("50")
      end

      test "to_fhir includes active status" do
        org = Organization.new(ien: 100, name: "Test", active: true)
        fhir = org.to_fhir

        assert_equal true, fhir[:active]
      end

      test "to_fhir includes fax and email in telecom" do
        org = Organization.new(
          ien: 100, name: "Test",
          phone: "907-555-1234", fax: "907-555-1235", email: "info@test.org"
        )
        fhir = org.to_fhir

        assert_equal 3, fhir[:telecom].count
        phone = fhir[:telecom].find { |t| t[:system] == "phone" }
        assert_equal "907-555-1234", phone[:value]
        fax = fhir[:telecom].find { |t| t[:system] == "fax" }
        assert_equal "907-555-1235", fax[:value]
        email = fhir[:telecom].find { |t| t[:system] == "email" }
        assert_equal "info@test.org", email[:value]
      end

      test "resource_class returns Organization" do
        assert_equal "Organization", Organization.resource_class
      end

      test "from_fhir_attributes extracts attributes" do
        fhir_resource = OpenStruct.new(
          name: "FHIR Hospital",
          active: true,
          identifier: [
            OpenStruct.new(system: "http://hl7.org/fhir/sid/us-npi", value: "9876543210")
          ],
          type: [
            OpenStruct.new(coding: [ OpenStruct.new(code: "prov") ])
          ]
        )

        attrs = Organization.from_fhir_attributes(fhir_resource)
        assert_equal "FHIR Hospital", attrs[:name]
        assert_equal "9876543210", attrs[:npi]
        assert_equal "prov", attrs[:org_type]
        assert_equal true, attrs[:active]
      end

      test "from_fhir creates organization from FHIR resource" do
        fhir_resource = OpenStruct.new(
          name: "External Org",
          active: true,
          identifier: [],
          type: []
        )

        org = Organization.from_fhir(fhir_resource)
        assert org.is_a?(Organization)
        assert_equal "External Org", org.name
      end

      # =============================================================================
      # US CORE / TEFCA COMPLIANCE TESTS
      # =============================================================================

      test "organization FHIR is US Core compliant" do
        org = Organization.new(
          ien: 100, name: "US Core Compliant Org",
          org_type: "prov", npi: "1234567890", active: true
        )
        fhir = org.to_fhir

        assert fhir[:name].present?, "US Core requires name"
        assert fhir[:identifier]&.any?, "US Core should have identifier"
      end

      test "organization with NPI ready for QHIN exchange" do
        org = Organization.new(
          ien: 100, name: "QHIN Exchange Org",
          org_type: "prov", npi: "1234567890"
        )
        fhir = org.to_fhir

        npi_id = fhir[:identifier].find { |id| id[:system]&.include?("npi") }
        assert_not_nil npi_id, "NPI required for QHIN exchange"
        assert_equal 10, npi_id[:value].length
      end

      test "organization FHIR can be serialized to JSON" do
        org = Organization.new(
          ien: 100, name: "JSON Test",
          org_type: "prov", npi: "1234567890"
        )

        assert_nothing_raised do
          org.to_fhir.to_json
        end
      end

      # =============================================================================
      # HIERARCHY TESTS
      # =============================================================================

      test "parent_organization returns nil when not set" do
        org = Organization.new(name: "Standalone")
        assert_nil org.parent_organization
      end

      # =============================================================================
      # EDGE CASES (existing)
      # =============================================================================

      test "find_by_ien returns nil for nil" do
        assert_nil Organization.find_by_ien(nil)
      end

      test "find_by_ien returns nil for zero" do
        assert_nil Organization.find_by_ien(0)
      end

      test "to_param returns IEN string" do
        org = Organization.new(ien: 1, name: "Test")
        assert_equal "1", org.to_param
      end
    end
  end
end
