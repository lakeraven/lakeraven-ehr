# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # Issue #239 — CoverageSummaryService payer order (factory spec, panel round 1).
    class CoverageSummaryServiceSpecTest < ActiveSupport::TestCase
      PRC_PAYER = CoverageSummaryService::PRC_PAYER

      def build_referral_service_request
        patient = Patient.new(dfn: 1, name: "TEST,PATIENT", sex: "M")
        sr = ServiceRequest.new(
          ien: 1,
          patient_dfn: 1,
          requesting_provider_ien: 101,
          service_requested: "Cardiology Consult",
          reason_for_referral: "Service not available at IHS facility",
          urgency: "ROUTINE",
          status: "draft"
        )
        sr.define_singleton_method(:patient) { patient }
        sr.define_singleton_method(:urgency_symbol) { :routine }
        sr
      end

      test "without referral context payer hierarchy omits PRC" do
        coverages = [
          Coverage.new(patient_dfn: "1", coverage_type: "medicare_a", status: "active"),
          Coverage.new(patient_dfn: "1", coverage_type: "medicaid", status: "active")
        ]

        hierarchy = CoverageSummaryService.new(coverages).determine_payer_hierarchy

        assert_equal [ "Medicare", "Medicaid" ], hierarchy
        refute_includes hierarchy, PRC_PAYER
      end

      test "referral context lists active payers in hierarchy order then PRC once" do
        service_request = build_referral_service_request
        coverages = [
          Coverage.new(patient_dfn: "1", coverage_type: "medicare_a", status: "active"),
          Coverage.new(patient_dfn: "1", coverage_type: "medicaid", status: "active")
        ]

        hierarchy = CoverageSummaryService.new(coverages, service_request: service_request).determine_payer_hierarchy

        assert_equal [ "Medicare", "Medicaid", PRC_PAYER ], hierarchy
        assert_equal 1, hierarchy.count(PRC_PAYER)
      end

      test "referral with workers comp and private insurance appends PRC after both actives" do
        service_request = build_referral_service_request
        coverages = [
          Coverage.new(patient_dfn: "1", coverage_type: "private_insurance", status: "active", payor_name: "Blue Cross"),
          Coverage.new(patient_dfn: "1", coverage_type: "workers_comp", status: "active", payor_name: "Workers Compensation")
        ]

        hierarchy = CoverageSummaryService.new(coverages, service_request: service_request).determine_payer_hierarchy

        assert_equal [ "Workers Compensation", "Blue Cross", PRC_PAYER ], hierarchy
      end

      test "referral Medicaid-only hierarchy ends with PRC" do
        service_request = build_referral_service_request
        coverages = [
          Coverage.new(patient_dfn: "1", coverage_type: "medicaid", status: "active")
        ]

        hierarchy = CoverageSummaryService.new(coverages, service_request: service_request).determine_payer_hierarchy

        assert_equal [ "Medicaid", PRC_PAYER ], hierarchy
      end

      test "referral VA-only hierarchy ends with PRC" do
        service_request = build_referral_service_request
        coverages = [
          Coverage.new(patient_dfn: "1", coverage_type: "va_benefits", status: "active")
        ]

        hierarchy = CoverageSummaryService.new(coverages, service_request: service_request).determine_payer_hierarchy

        assert_equal [ "Department of Veterans Affairs", PRC_PAYER ], hierarchy
      end

      test "referral excludes expired coverage from payer order before PRC" do
        service_request = build_referral_service_request
        coverages = [
          Coverage.new(
            patient_dfn: "1",
            coverage_type: "private_insurance",
            status: "active",
            payor_name: "Blue Cross",
            start_date: 3.years.ago,
            end_date: 1.year.ago
          ),
          Coverage.new(patient_dfn: "1", coverage_type: "medicaid", status: "active")
        ]

        hierarchy = CoverageSummaryService.new(coverages, service_request: service_request).determine_payer_hierarchy

        assert_equal [ "Medicaid", PRC_PAYER ], hierarchy
        refute_includes hierarchy, "Blue Cross"
      end

      test "referral with no active coverage makes PRC the primary payer" do
        service_request = build_referral_service_request
        coverages = [
          Coverage.new(patient_dfn: "1", coverage_type: "medicare_a", status: "cancelled")
        ]

        summary = CoverageSummaryService.new(coverages, service_request: service_request).summarize

        assert_equal PRC_PAYER, summary.primary_payer
        assert_equal [ PRC_PAYER ], summary.payer_hierarchy
      end
    end
  end
end
