# frozen_string_literal: true

require "test_helper"
require "ostruct"

module Lakeraven
  module EHR
    class ConsentTest < ActiveSupport::TestCase
      # =============================================================================
      # VALIDATION TESTS
      # =============================================================================

      test "should be valid with required attributes" do
        consent = Consent.new(patient_dfn: "12345", scope: "patient-privacy")
        assert consent.valid?, "Consent should be valid with patient and scope"
      end

      test "should require patient_dfn" do
        consent = Consent.new(scope: "patient-privacy")
        refute consent.valid?
        assert consent.errors[:patient_dfn].any?
      end

      test "should require scope" do
        consent = Consent.new(patient_dfn: "12345")
        refute consent.valid?
        assert consent.errors[:scope].any?
      end

      test "should validate scope is in allowed list" do
        consent = Consent.new(patient_dfn: "12345", scope: "invalid-scope")
        refute consent.valid?
        assert_includes consent.errors[:scope], "is not included in the list"
      end

      test "should validate status if present" do
        consent = Consent.new(patient_dfn: "12345", scope: "patient-privacy", status: "invalid")
        refute consent.valid?
        assert_includes consent.errors[:status], "is not included in the list"
      end

      test "should validate provision_type if present" do
        consent = Consent.new(patient_dfn: "12345", scope: "patient-privacy", provision_type: "invalid")
        refute consent.valid?
        assert_includes consent.errors[:provision_type], "is not included in the list"
      end

      # =============================================================================
      # STATUS HELPER TESTS
      # =============================================================================

      test "active? returns true for active status" do
        assert Consent.new(status: "active").active?
      end

      test "draft? returns true for draft status" do
        assert Consent.new(status: "draft").draft?
      end

      test "proposed? returns true for proposed status" do
        assert Consent.new(status: "proposed").proposed?
      end

      test "rejected? returns true for rejected status" do
        assert Consent.new(status: "rejected").rejected?
      end

      test "inactive? returns true for inactive status" do
        assert Consent.new(status: "inactive").inactive?
      end

      test "enforceable? returns true only for active status" do
        assert Consent.new(status: "active").enforceable?
        refute Consent.new(status: "draft").enforceable?
        refute Consent.new(status: "proposed").enforceable?
        refute Consent.new(status: "rejected").enforceable?
        refute Consent.new(status: "inactive").enforceable?
      end

      test "status_display returns human-readable status" do
        consent = Consent.new(status: "active")
        assert_equal "Active", consent.status_display

        consent.status = "draft"
        assert_equal "Draft", consent.status_display

        consent.status = nil
        assert_equal "Unknown", consent.status_display
      end

      # =============================================================================
      # SCOPE HELPER TESTS
      # =============================================================================

      test "scope_display returns human-readable scope" do
        consent = Consent.new(scope: "patient-privacy")
        assert_equal "Privacy Consent", consent.scope_display

        consent.scope = "treatment"
        assert_equal "Treatment", consent.scope_display

        consent.scope = "research"
        assert_equal "Research", consent.scope_display

        consent.scope = nil
        assert_equal "Unknown", consent.scope_display
      end

      test "patient_privacy? returns true for patient-privacy scope" do
        assert Consent.new(scope: "patient-privacy").patient_privacy?
      end

      test "treatment? returns true for treatment scope" do
        assert Consent.new(scope: "treatment").treatment?
      end

      test "research? returns true for research scope" do
        assert Consent.new(scope: "research").research?
      end

      # =============================================================================
      # PROVISION HELPER TESTS
      # =============================================================================

      test "permits? returns true for permit provision" do
        assert Consent.new(provision_type: "permit").permits?
      end

      test "denies? returns true for deny provision" do
        assert Consent.new(provision_type: "deny").denies?
      end

      test "provision_type_display returns human-readable provision type" do
        consent = Consent.new(provision_type: "permit")
        assert_equal "Permit", consent.provision_type_display

        consent.provision_type = "deny"
        assert_equal "Deny", consent.provision_type_display
      end

      # =============================================================================
      # VALIDITY PERIOD TESTS
      # =============================================================================

      test "within_period? returns true when no period set" do
        consent = Consent.new(patient_dfn: "12345", scope: "patient-privacy")
        assert consent.within_period?
      end

      test "within_period? returns true when within period" do
        consent = Consent.new(
          patient_dfn: "12345",
          scope: "patient-privacy",
          period_start: Date.current - 1.year,
          period_end: Date.current + 1.year
        )
        assert consent.within_period?
      end

      test "within_period? returns false when before period" do
        consent = Consent.new(
          patient_dfn: "12345",
          scope: "patient-privacy",
          period_start: Date.current + 1.month
        )
        refute consent.within_period?
      end

      test "within_period? returns false when after period" do
        consent = Consent.new(
          patient_dfn: "12345",
          scope: "patient-privacy",
          period_end: Date.current - 1.month
        )
        refute consent.within_period?
      end

      # =============================================================================
      # AUTHORIZATION TESTS
      # =============================================================================

      test "authorizes_access? returns true when enforceable and permits" do
        consent = Consent.new(
          patient_dfn: "12345",
          scope: "patient-privacy",
          status: "active",
          provision_type: "permit"
        )
        assert consent.authorizes_access?
      end

      test "authorizes_access? returns false when not active" do
        consent = Consent.new(
          patient_dfn: "12345",
          scope: "patient-privacy",
          status: "inactive",
          provision_type: "permit"
        )
        refute consent.authorizes_access?
      end

      test "authorizes_access? returns false when denies" do
        consent = Consent.new(
          patient_dfn: "12345",
          scope: "patient-privacy",
          status: "active",
          provision_type: "deny"
        )
        refute consent.authorizes_access?
      end

      test "authorizes_access? returns false when outside period" do
        consent = Consent.new(
          patient_dfn: "12345",
          scope: "patient-privacy",
          status: "active",
          provision_type: "permit",
          period_end: Date.current - 1.month
        )
        refute consent.authorizes_access?
      end

      # =============================================================================
      # ALLOWS PERMISSION
      # =============================================================================

      test "allows? returns true for matching scope" do
        consent = Consent.new(status: "active", scope: "view_referrals")
        assert consent.allows?(:view_referrals)
      end

      test "allows? returns true for full_access" do
        consent = Consent.new(status: "active", scope: "full_access")
        assert consent.allows?(:view_referrals)
      end

      test "allows? returns false for non-matching scope" do
        consent = Consent.new(status: "active", scope: "view_referrals")
        refute consent.allows?(:upload_docs)
      end

      test "allows? returns false when not active" do
        consent = Consent.new(status: "draft", scope: "full_access")
        refute consent.allows?(:view_referrals)
      end

      # =============================================================================
      # EXPIRED
      # =============================================================================

      test "expired? returns true when expires_at is past" do
        consent = Consent.new(expires_at: 1.day.ago)
        assert consent.expired?
      end

      test "expired? returns false when expires_at is future" do
        consent = Consent.new(expires_at: 1.day.from_now)
        refute consent.expired?
      end

      test "expired? returns false when expires_at is nil" do
        consent = Consent.new(expires_at: nil)
        refute consent.expired?
      end

      # =============================================================================
      # PERSISTENCE TESTS
      # =============================================================================

      test "persisted? returns false for new consent without id" do
        consent = Consent.new(patient_dfn: "12345", scope: "patient-privacy")
        refute consent.persisted?
      end

      test "persisted? returns true when id present" do
        consent = Consent.new(id: "42")
        assert consent.persisted?
      end

      # =============================================================================
      # FHIR SERIALIZATION TESTS
      # =============================================================================

      test "to_fhir returns valid FHIR Consent resource" do
        consent = Consent.new(
          id: "42",
          patient_dfn: "12345",
          scope: "patient-privacy",
          status: "active"
        )
        fhir = consent.to_fhir

        assert_equal "Consent", fhir[:resourceType]
        assert_equal "42", fhir[:id]
        assert_equal "active", fhir[:status]
      end

      test "to_fhir includes patient reference" do
        consent = Consent.new(patient_dfn: "12345", scope: "patient-privacy")
        fhir = consent.to_fhir

        assert_not_nil fhir[:patient]
        assert_equal "Patient/12345", fhir[:patient][:reference]
      end

      test "to_fhir includes scope coding" do
        consent = Consent.new(patient_dfn: "12345", scope: "patient-privacy")
        fhir = consent.to_fhir

        assert_not_nil fhir[:scope]
        coding = fhir[:scope][:coding].first
        assert_equal "patient-privacy", coding[:code]
        assert_equal "Privacy Consent", coding[:display]
      end

      test "to_fhir includes category" do
        consent = Consent.new(patient_dfn: "12345", scope: "patient-privacy")
        fhir = consent.to_fhir

        assert fhir[:category].any?
        coding = fhir[:category].first[:coding].first
        assert_equal "59284-0", coding[:code]
        assert_equal "Consent Document", coding[:display]
      end

      test "to_fhir includes dateTime" do
        consent = Consent.new(
          patient_dfn: "12345",
          scope: "patient-privacy",
          date_time: Date.parse("2024-06-15")
        )
        fhir = consent.to_fhir

        assert_equal "2024-06-15", fhir[:dateTime]
      end

      test "to_fhir includes performer" do
        consent = Consent.new(
          patient_dfn: "12345",
          scope: "patient-privacy",
          performer_ien: "101"
        )
        fhir = consent.to_fhir

        assert fhir[:performer].any?
        performer = fhir[:performer].first
        assert performer[:reference].include?("Practitioner")
        assert performer[:reference].include?("101")
      end

      test "to_fhir includes provision" do
        consent = Consent.new(
          patient_dfn: "12345",
          scope: "patient-privacy",
          provision_type: "permit"
        )
        fhir = consent.to_fhir

        assert_not_nil fhir[:provision]
        assert_equal "permit", fhir[:provision][:type]
      end

      test "to_fhir includes provision actor for related person" do
        consent = Consent.new(
          patient_dfn: "12345",
          scope: "patient-privacy",
          provision_type: "permit",
          provision_actor_related_person_id: "rp-123"
        )
        fhir = consent.to_fhir

        assert fhir[:provision][:actor].any?
        actor = fhir[:provision][:actor].first
        assert actor[:reference][:reference].include?("RelatedPerson")
      end

      test "resource_class returns Consent" do
        assert_equal "Consent", Consent.resource_class
      end

      test "from_fhir_attributes extracts attributes" do
        fhir_resource = OpenStruct.new(
          status: "active",
          scope: OpenStruct.new(coding: [ OpenStruct.new(code: "patient-privacy") ]),
          patient: OpenStruct.new(reference: "Patient/12345"),
          dateTime: "2024-06-15"
        )

        attrs = Consent.from_fhir_attributes(fhir_resource)
        assert_equal "active", attrs[:status]
        assert_equal "patient-privacy", attrs[:scope]
        assert_equal "12345", attrs[:patient_dfn]
        assert_equal Date.parse("2024-06-15"), attrs[:date_time]
      end

      test "from_fhir creates consent from FHIR resource" do
        fhir_resource = OpenStruct.new(
          status: "active",
          scope: OpenStruct.new(coding: [ OpenStruct.new(code: "patient-privacy") ]),
          patient: OpenStruct.new(reference: "Patient/12345")
        )

        consent = Consent.from_fhir(fhir_resource)
        assert consent.is_a?(Consent)
        assert_equal "active", consent.status
        assert_equal "patient-privacy", consent.scope
        assert_equal "12345", consent.patient_dfn
      end

      # =============================================================================
      # EDGE CASE TESTS
      # =============================================================================

      test "handles nil performer in FHIR" do
        consent = Consent.new(
          patient_dfn: "12345",
          scope: "patient-privacy",
          performer_ien: nil
        )
        fhir = consent.to_fhir

        assert_equal [], fhir[:performer]
      end

      test "handles nil provision in FHIR" do
        consent = Consent.new(
          patient_dfn: "12345",
          scope: "patient-privacy",
          provision_type: nil
        )
        fhir = consent.to_fhir

        assert_nil fhir[:provision]
      end

      test "handles nil dateTime in FHIR" do
        consent = Consent.new(
          patient_dfn: "12345",
          scope: "patient-privacy",
          date_time: nil
        )
        fhir = consent.to_fhir

        assert_nil fhir[:dateTime]
      end
    end
  end
end
