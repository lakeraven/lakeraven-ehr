# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class AlternateResourceServiceTest < ActiveSupport::TestCase
      # =========================================================================
      # SERVICE NOT AVAILABLE AT IHS FACILITY
      # =========================================================================

      test "specialty not available at IHS facility is valid alternate resource" do
        sr = build_sr(
          service_requested: "Neurosurgery",
          reason_for_referral: "Complex brain surgery not available at IHS facility"
        )

        result = AlternateResourceService.check(sr)

        assert result.service_unavailable_at_ihs?
        assert result.valid_alternate_resource_reason?
        assert result.message.include?("not available at IHS")
      end

      test "specialized equipment not available justifies external service request" do
        sr = build_sr(
          service_requested: "Advanced cardiac imaging",
          reason_for_referral: "Requires cardiac MRI not available at IHS facility"
        )

        result = AlternateResourceService.check(sr)

        assert result.valid_alternate_resource_reason?
        assert result.justification_keywords.include?("not available")
      end

      test "wait time exceeds clinical appropriateness" do
        sr = build_sr(
          service_requested: "Orthopedic Surgery",
          reason_for_referral: "Surgery wait time at IHS exceeds clinical appropriateness (>6 months)",
          urgency: "URGENT"
        )

        result = AlternateResourceService.check(sr)

        assert result.valid_alternate_resource_reason?
        assert result.justification_keywords.include?("wait time")
      end

      # =========================================================================
      # INVALID ALTERNATE RESOURCE REASONS
      # =========================================================================

      test "patient preference alone is not valid alternate resource reason" do
        sr = build_sr(
          service_requested: "Primary Care",
          reason_for_referral: "Patient prefers external provider"
        )

        result = AlternateResourceService.check(sr)

        assert_not result.valid_alternate_resource_reason?
        assert result.message.include?("Patient preference alone is not sufficient")
      end

      test "service available at IHS fails alternate resource check" do
        sr = build_sr(
          service_requested: "General Surgery",
          reason_for_referral: "Patient needs routine surgical consultation"
        )

        result = AlternateResourceService.check(sr)

        assert_not result.service_unavailable_at_ihs?
        assert_not result.valid_alternate_resource_reason?
      end

      test "vague justification fails alternate resource check" do
        sr = build_sr(
          service_requested: "Specialty consultation",
          reason_for_referral: "Patient needs to see specialist"
        )

        result = AlternateResourceService.check(sr)

        assert_not result.valid_alternate_resource_reason?
        assert result.message.include?("Insufficient justification")
      end

      # =========================================================================
      # SPECIALIST EXPERTISE REQUIREMENTS
      # =========================================================================

      test "specialized expertise not available at IHS is valid reason" do
        sr = build_sr(
          service_requested: "Pediatric Cardiac Surgery",
          reason_for_referral: "Complex pediatric cardiac procedure requires specialized expertise not available at IHS"
        )

        result = AlternateResourceService.check(sr)

        assert result.valid_alternate_resource_reason?
        assert result.specialty_expertise_required?
        assert result.justification_keywords.include?("specialized expertise")
      end

      test "subspecialty care justifies external service request" do
        sr = build_sr(
          service_requested: "Interventional Cardiology",
          reason_for_referral: "Requires interventional cardiology subspecialty not staffed at IHS"
        )

        result = AlternateResourceService.check(sr)

        assert result.valid_alternate_resource_reason?
        assert result.justification_keywords.include?("subspecialty")
      end

      # =========================================================================
      # EMERGENCY/URGENT CARE SCENARIOS
      # =========================================================================

      test "emergency care not immediately available at IHS justifies external service request" do
        sr = build_sr(
          service_requested: "Emergency Cardiac Care",
          reason_for_referral: "Life-threatening cardiac emergency, IHS cardiac cath lab not available",
          urgency: "EMERGENT"
        )

        result = AlternateResourceService.check(sr)

        assert result.valid_alternate_resource_reason?
        assert result.emergency_alternate_resource?
        assert result.urgency_supports_alternate_resource?
      end

      test "urgent care with critical wait time justifies external service request" do
        sr = build_sr(
          service_requested: "Urgent Neurosurgery",
          reason_for_referral: "Urgent neurosurgical evaluation needed, IHS neurosurgeon on leave for 3 weeks",
          urgency: "URGENT"
        )

        result = AlternateResourceService.check(sr)

        assert result.valid_alternate_resource_reason?
        assert result.urgency_supports_alternate_resource?
      end

      # =========================================================================
      # DOCUMENTATION REQUIREMENTS
      # =========================================================================

      test "alternate resource check validates documentation completeness" do
        sr = build_sr(
          service_requested: "Specialty Cardiology",
          reason_for_referral: "Advanced cardiac imaging not available at IHS facility. Cardiac MRI required for diagnosis."
        )

        result = AlternateResourceService.check(sr)

        assert result.documentation_complete?
        assert result.specific_service_identified?
        assert result.ihs_limitation_documented?
      end

      test "incomplete documentation fails alternate resource check" do
        sr = build_sr(
          service_requested: "Specialty",
          reason_for_referral: "Not available"
        )

        result = AlternateResourceService.check(sr)

        assert_not result.documentation_complete?
        assert result.message.include?("documentation incomplete")
      end

      # =========================================================================
      # IHS CAPABILITY VERIFICATION
      # =========================================================================

      test "IHS capability check for common services" do
        common_services = [ "Primary Care", "General Surgery", "Internal Medicine", "Family Medicine" ]

        common_services.each do |service|
          sr = build_sr(service_requested: service, reason_for_referral: "Patient needs #{service}")
          result = AlternateResourceService.check(sr)
          assert_not result.service_unavailable_at_ihs?, "#{service} should be available at IHS"
        end
      end

      test "IHS capability check for specialized services" do
        specialized_services = [ "Neurosurgery", "Interventional Cardiology", "Pediatric Cardiac Surgery", "Radiation Oncology" ]

        specialized_services.each do |service|
          sr = build_sr(
            service_requested: service,
            reason_for_referral: "#{service} not available at IHS facility"
          )
          result = AlternateResourceService.check(sr)
          assert result.service_unavailable_at_ihs? || result.specialty_expertise_required?,
            "#{service} should be recognized as specialized"
        end
      end

      # =========================================================================
      # REFERRAL TYPE VALIDATION
      # =========================================================================

      test "inpatient service request requires stronger justification" do
        sr = build_sr(
          service_requested: "Inpatient Surgery",
          reason_for_referral: "Complex surgical procedure requiring inpatient care not available at IHS"
        )

        result = AlternateResourceService.check(sr)

        assert result.valid_alternate_resource_reason?
        assert result.inpatient_justification_adequate?
      end

      test "outpatient service request with basic justification is sufficient" do
        sr = build_sr(
          service_requested: "Specialty consultation",
          reason_for_referral: "Specialty not available at IHS facility"
        )

        result = AlternateResourceService.check(sr)

        assert result.valid_alternate_resource_reason?
      end

      # =========================================================================
      # COMPLETE WORKFLOW TESTS
      # =========================================================================

      test "complete alternate resource validation for valid external service request" do
        sr = build_sr(
          service_requested: "Cardiac Catheterization",
          reason_for_referral: "Cardiac catheterization lab not available at IHS facility. Patient requires diagnostic cardiac cath for evaluation of coronary artery disease.",
          urgency: "URGENT"
        )

        result = AlternateResourceService.check(sr)

        assert result.valid_alternate_resource_reason?
        assert result.service_unavailable_at_ihs?
        assert result.documentation_complete?
        assert result.specific_service_identified?
        assert result.compliant?
      end

      test "alternate resource check fails for inappropriate service request" do
        sr = build_sr(
          service_requested: "Primary Care",
          reason_for_referral: "Patient wants to see different doctor",
          urgency: "ROUTINE"
        )

        result = AlternateResourceService.check(sr)

        assert_not result.valid_alternate_resource_reason?
        assert_not result.service_unavailable_at_ihs?
        assert_not result.compliant?
        assert result.denial_reasons.any?
      end

      # =========================================================================
      # TERMINOLOGY SERVICE INTEGRATION
      # =========================================================================

      test "falls back to constants when TerminologyService unavailable" do
        AlternateResourceService.terminology_service = nil

        sr = build_sr(
          service_requested: "Primary Care",
          reason_for_referral: "Routine checkup"
        )

        result = AlternateResourceService.check(sr)

        assert result.service_available_at_ihs?
      ensure
        AlternateResourceService.terminology_service = nil
      end

      test "falls back gracefully when TerminologyService raises error" do
        mock_ts = Object.new
        mock_ts.define_singleton_method(:expand_valueset) { |*_args| raise TerminologyService::ValueSetNotFoundError, "Test error" }

        AlternateResourceService.terminology_service = mock_ts

        sr = build_sr(
          service_requested: "Primary Care",
          reason_for_referral: "Routine checkup"
        )

        result = AlternateResourceService.check(sr)

        assert result.service_available_at_ihs?
      ensure
        AlternateResourceService.terminology_service = nil
      end

      private

      def build_sr(attrs = {})
        defaults = {
          ien: 1,
          patient_dfn: 1,
          requesting_provider_ien: 101,
          service_requested: "Specialty consultation",
          reason_for_referral: "Clinical evaluation required",
          urgency: "ROUTINE",
          status: "draft"
        }
        sr = ServiceRequest.new(defaults.merge(attrs))
        # Wire up alternate_resource_justification stubs for legacy keyword path
        sr.define_singleton_method(:alternate_resource_justification) { nil }
        sr.define_singleton_method(:alternate_resource_justification_symbol) { nil }
        sr.define_singleton_method(:referral_type) { attrs[:referral_type] || "OUTPATIENT" }
        sr
      end
    end
  end
end
