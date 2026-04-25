# frozen_string_literal: true

require "test_helper"

# Tests for PractitionerGateway — the repository layer that owns
# all RPMS RPC details for practitioner/provider data.
# Uses mock data seeded in test_helper.rb via RpmsRpc.mock!
module Lakeraven
  module EHR
    class PractitionerGatewayTest < ActiveSupport::TestCase
      # === find ===

      test "find returns practitioner by IEN" do
        practitioner = PractitionerGateway.find(101)

        assert_not_nil practitioner, "Should find practitioner"
        assert_instance_of Practitioner, practitioner
        assert_equal 101, practitioner.ien
        assert_equal "MARTINEZ,SARAH", practitioner.name
        assert_equal "MD", practitioner.title
        assert_equal "Internal Medicine", practitioner.service_section
        assert_equal "Cardiology", practitioner.specialty
        assert_equal "1234567890", practitioner.npi
        assert_equal "AM1234563", practitioner.dea_number
        assert_equal "907-555-9999", practitioner.phone
        assert_equal "Physician", practitioner.provider_class
      end

      test "find returns second practitioner" do
        practitioner = PractitionerGateway.find(102)

        assert_not_nil practitioner
        assert_equal "CHEN,JAMES", practitioner.name
        assert_equal "DO", practitioner.title
        assert_equal "Orthopedic Surgery", practitioner.specialty
      end

      test "find returns nil for invalid IEN" do
        practitioner = PractitionerGateway.find(999999)

        assert_nil practitioner, "Should return nil for non-existent practitioner"
      end

      # === search ===

      test "search returns practitioners matching name" do
        practitioners = PractitionerGateway.search("M")

        assert practitioners.is_a?(Array), "Should return array"
        assert practitioners.length >= 1, "Should find at least one match"

        practitioners.each do |prac|
          assert_instance_of Practitioner, prac
          assert prac.name.present?, "Practitioner should have name"
        end
      end

      test "search returns empty array when no matches" do
        practitioners = PractitionerGateway.search("ZZZZNONEXISTENT")

        assert practitioners.is_a?(Array), "Should return array"
        assert_equal 0, practitioners.length
      end

      # === FHIR compatibility ===

      test "practitioner from gateway has FHIR-compatible attributes" do
        practitioner = PractitionerGateway.find(101)

        assert practitioner.respond_to?(:ien), "Should have ien"
        assert practitioner.respond_to?(:name), "Should have name"
        assert practitioner.respond_to?(:specialty), "Should have specialty"
        assert practitioner.respond_to?(:npi), "Should have npi"
        assert practitioner.respond_to?(:to_fhir), "Should be FHIR serializable"
      end

      test "practitioner from gateway is persisted" do
        practitioner = PractitionerGateway.find(101)

        assert practitioner.persisted?, "Practitioner with IEN should be persisted"
      end

      test "practitioner can_prescribe_controlled reflects DEA presence" do
        with_dea = PractitionerGateway.find(101)
        assert with_dea.can_prescribe_controlled?, "Practitioner with DEA should be able to prescribe"

        without_dea = PractitionerGateway.find(102)
        refute without_dea.can_prescribe_controlled?, "Practitioner without DEA should not be able to prescribe"
      end
    end
  end
end
