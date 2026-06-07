# frozen_string_literal: true

require "test_helper"

# Tests for PractitionerGateway — the repository layer that owns
# all RPMS RPC details for practitioner/provider data.
# Uses mock data seeded in test_helper.rb via RpmsRpc.mock!
module Lakeraven
  module EHR
    class PractitionerGatewayTest < ActiveSupport::TestCase
      # === find ===

      test "find returns practitioner by IEN when IEN matches session user" do
        # ORWU USERINFO returns the AUTHENTICATED session user only.
        # name + ien are surfaceable; title, service_section, specialty,
        # npi, dea_number, phone, provider_class come from a different
        # RPC not currently mapped (see rpms-rpc rr-fyf for the rationale).
        practitioner = PractitionerGateway.find(101)

        assert_not_nil practitioner, "Should find practitioner"
        assert_instance_of Practitioner, practitioner
        assert_equal 101, practitioner.ien
        assert_equal "MARTINEZ,SARAH", practitioner.name
      end

      test "find returns nil for IEN that does not match session user" do
        # ORWU USERINFO can't look up arbitrary IENs — see rpms-rpc rr-fyf.
        practitioner = PractitionerGateway.find(102)

        assert_nil practitioner
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

      test "can_prescribe_controlled reflects DEA presence on the model" do
        # Verified at the model level — the gateway can't surface a
        # practitioner's DEA number from ORWU USERINFO (see rr-fyf).
        with_dea = Practitioner.new(ien: 101, name: "MARTINEZ,SARAH", dea_number: "AM1234563")
        assert with_dea.can_prescribe_controlled?

        without_dea = Practitioner.new(ien: 102, name: "CHEN,JAMES", dea_number: nil)
        refute without_dea.can_prescribe_controlled?
      end
    end
  end
end
