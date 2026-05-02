# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    module FHIR
      class RemainingSerializersTest < ActiveSupport::TestCase
        # =============================================================================
        # CONSENT SERIALIZER
        # =============================================================================

        test "consent serializes resourceType" do
          consent = Consent.new(id: "c-001", patient_dfn: "1", scope: "patient-privacy", status: "active")
          result = ConsentSerializer.new(consent).to_h

          assert_equal "Consent", result[:resourceType]
        end

        test "consent includes patient reference" do
          consent = Consent.new(id: "c-001", patient_dfn: "1", scope: "patient-privacy", status: "active")
          result = ConsentSerializer.new(consent).to_h

          assert_equal "Patient/1", result[:patient][:reference]
        end

        test "consent includes scope coding" do
          consent = Consent.new(id: "c-001", patient_dfn: "1", scope: "patient-privacy", status: "active")
          result = ConsentSerializer.new(consent).to_h

          refute_nil result[:scope]
        end

        test "consent includes provision" do
          consent = Consent.new(id: "c-001", patient_dfn: "1", scope: "patient-privacy",
                                status: "active", provision_type: "permit")
          result = ConsentSerializer.new(consent).to_h

          refute_nil result[:provision]
        end

        test "consent handles minimal record" do
          consent = Consent.new(patient_dfn: "1", scope: "treatment")
          result = ConsentSerializer.new(consent).to_h

          assert_equal "Consent", result[:resourceType]
        end

        test "consent redaction policy applies" do
          consent = Consent.new(id: "c-001", patient_dfn: "1", scope: "patient-privacy", status: "active")
          policy = RedactionPolicy.new(view: :research)
          result = ConsentSerializer.new(consent, policy: policy).to_h

          assert_equal "Consent", result[:resourceType]
        end

        # =============================================================================
        # ORGANIZATION SERIALIZER
        # =============================================================================

        test "organization serializes resourceType" do
          org = Organization.new(ien: 1, name: "Alaska Native Medical Center", station_number: "463")
          result = OrganizationSerializer.new(org).to_h

          assert_equal "Organization", result[:resourceType]
        end

        test "organization includes name" do
          org = Organization.new(ien: 1, name: "Alaska Native Medical Center")
          result = OrganizationSerializer.new(org).to_h

          assert_equal "Alaska Native Medical Center", result[:name]
        end

        test "organization includes identifiers" do
          org = Organization.new(ien: 1, name: "ANMC", station_number: "463", npi: "1234567890")
          result = OrganizationSerializer.new(org).to_h

          refute_nil result[:identifier]
          assert result[:identifier].any?
        end

        test "organization handles minimal record" do
          org = Organization.new(ien: 1, name: "Test Org")
          result = OrganizationSerializer.new(org).to_h

          assert_equal "Organization", result[:resourceType]
        end

        test "organization redaction policy applies" do
          org = Organization.new(ien: 1, name: "ANMC")
          policy = RedactionPolicy.new(view: :research)
          result = OrganizationSerializer.new(org, policy: policy).to_h

          assert_equal "Organization", result[:resourceType]
        end

        # =============================================================================
        # LOCATION SERIALIZER
        # =============================================================================

        test "location serializes resourceType" do
          loc = Location.new(ien: 1, name: "Primary Care Clinic")
          result = LocationSerializer.new(loc).to_h

          assert_equal "Location", result[:resourceType]
        end

        test "location includes name" do
          loc = Location.new(ien: 1, name: "Primary Care Clinic")
          result = LocationSerializer.new(loc).to_h

          assert_equal "Primary Care Clinic", result[:name]
        end

        test "location includes identifier" do
          loc = Location.new(ien: 1, name: "PCC", abbreviation: "PCC")
          result = LocationSerializer.new(loc).to_h

          refute_nil result[:identifier]
        end

        test "location includes managing organization when present" do
          loc = Location.new(ien: 1, name: "PCC", managing_organization_ien: 100)
          result = LocationSerializer.new(loc).to_h

          refute_nil result[:managingOrganization]
        end

        test "location handles minimal record" do
          loc = Location.new(ien: 1, name: "Test")
          result = LocationSerializer.new(loc).to_h

          assert_equal "Location", result[:resourceType]
        end

        test "location redaction policy applies" do
          loc = Location.new(ien: 1, name: "PCC")
          policy = RedactionPolicy.new(view: :research)
          result = LocationSerializer.new(loc, policy: policy).to_h

          assert_equal "Location", result[:resourceType]
        end

        # =============================================================================
        # PRACTITIONER ROLE SERIALIZER
        # =============================================================================

        test "practitioner_role serializes resourceType" do
          role = PractitionerRole.new(practitioner_ien: 101, role: "Primary Care Provider",
                                      specialty: "Family Medicine", active: true)
          result = PractitionerRoleSerializer.new(role).to_h

          assert_equal "PractitionerRole", result[:resourceType]
        end

        test "practitioner_role includes practitioner reference" do
          role = PractitionerRole.new(practitioner_ien: 101, role: "PCP", active: true)
          result = PractitionerRoleSerializer.new(role).to_h

          refute_nil result[:practitioner]
          assert_includes result[:practitioner][:reference], "101"
        end

        test "practitioner_role includes specialty" do
          role = PractitionerRole.new(practitioner_ien: 101, role: "PCP",
                                      specialty: "Cardiology", active: true)
          result = PractitionerRoleSerializer.new(role).to_h

          refute_nil result[:specialty]
        end

        test "practitioner_role redaction policy applies" do
          role = PractitionerRole.new(practitioner_ien: 101, role: "PCP", active: true)
          policy = RedactionPolicy.new(view: :research)
          result = PractitionerRoleSerializer.new(role, policy: policy).to_h

          assert_equal "PractitionerRole", result[:resourceType]
        end
      end
    end
  end
end
