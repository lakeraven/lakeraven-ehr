# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class CoverageSummaryServiceTest < ActiveSupport::TestCase
      # =============================================================================
      # PAYER HIERARCHY
      # =============================================================================

      test "determines payer hierarchy with single coverage" do
        coverages = [
          Coverage.new(patient_dfn: "12345", coverage_type: "medicare_a", status: "active")
        ]

        service = CoverageSummaryService.new(coverages)
        hierarchy = service.determine_payer_hierarchy

        assert_equal [ "Medicare" ], hierarchy
      end

      test "determines payer hierarchy with multiple coverages" do
        coverages = [
          Coverage.new(patient_dfn: "12345", coverage_type: "medicare_a", status: "active"),
          Coverage.new(patient_dfn: "12345", coverage_type: "medicaid", status: "active"),
          Coverage.new(patient_dfn: "12345", coverage_type: "private_insurance", status: "active", payor_name: "Blue Cross")
        ]

        service = CoverageSummaryService.new(coverages)
        hierarchy = service.determine_payer_hierarchy

        assert_equal "Blue Cross", hierarchy[0]
        assert_equal "Medicare", hierarchy[1]
        assert_equal "Medicaid", hierarchy[2]
      end

      test "private insurance is primary over Medicare" do
        coverages = [
          Coverage.new(patient_dfn: "12345", coverage_type: "medicare_b", status: "active"),
          Coverage.new(patient_dfn: "12345", coverage_type: "private_insurance", status: "active", payor_name: "Employer Plan")
        ]

        service = CoverageSummaryService.new(coverages)

        assert_equal "Employer Plan", service.primary_payer
        assert_includes service.secondary_payers, "Medicare"
      end

      test "workers comp is primary for work injuries" do
        coverages = [
          Coverage.new(patient_dfn: "12345", coverage_type: "medicare_a", status: "active"),
          Coverage.new(patient_dfn: "12345", coverage_type: "workers_comp", status: "active", payor_name: "Workers Compensation")
        ]

        service = CoverageSummaryService.new(coverages)

        assert_equal "Workers Compensation", service.primary_payer
      end

      test "auto insurance is primary for auto accidents" do
        coverages = [
          Coverage.new(patient_dfn: "12345", coverage_type: "medicare_a", status: "active"),
          Coverage.new(patient_dfn: "12345", coverage_type: "auto_insurance", status: "active", payor_name: "Auto Insurance")
        ]

        service = CoverageSummaryService.new(coverages)

        assert_equal "Auto Insurance", service.primary_payer
      end

      test "Medicaid is last before PRC" do
        coverages = [
          Coverage.new(patient_dfn: "12345", coverage_type: "medicaid", status: "active"),
          Coverage.new(patient_dfn: "12345", coverage_type: "medicare_a", status: "active")
        ]

        service = CoverageSummaryService.new(coverages)
        hierarchy = service.determine_payer_hierarchy

        assert_equal "Medicare", hierarchy[0]
        assert_equal "Medicaid", hierarchy[1]
      end

      # =============================================================================
      # PRC ELIGIBILITY
      # =============================================================================

      test "prc_eligible? returns true when active coverages exist" do
        coverages = [
          Coverage.new(patient_dfn: "12345", coverage_type: "medicare_a", status: "active")
        ]

        service = CoverageSummaryService.new(coverages)

        assert service.prc_eligible?
      end

      test "prc_eligible? returns true when all coverages exhausted" do
        coverages = [
          Coverage.new(patient_dfn: "12345", coverage_type: "medicare_a", status: "exhausted"),
          Coverage.new(patient_dfn: "12345", coverage_type: "medicaid", status: "not_enrolled")
        ]

        service = CoverageSummaryService.new(coverages)

        assert service.prc_eligible?
      end

      test "requires_coordination? returns true when active coverages exist" do
        coverages = [
          Coverage.new(patient_dfn: "12345", coverage_type: "private_insurance", status: "active", payor_name: "Blue Cross")
        ]

        service = CoverageSummaryService.new(coverages)

        assert service.requires_coordination?
      end

      test "requires_coordination? returns false when no active coverages" do
        coverages = [
          Coverage.new(patient_dfn: "12345", coverage_type: "medicare_a", status: "cancelled")
        ]

        service = CoverageSummaryService.new(coverages)

        refute service.requires_coordination?
      end

      # =============================================================================
      # SUMMARY GENERATION
      # =============================================================================

      test "summarize returns complete summary" do
        coverages = [
          Coverage.new(patient_dfn: "12345", coverage_type: "medicare_a", status: "active",
                       start_date: Date.current - 1.year, end_date: Date.current + 1.year),
          Coverage.new(patient_dfn: "12345", coverage_type: "medicaid", status: "exhausted"),
          Coverage.new(patient_dfn: "12345", coverage_type: "private_insurance", status: "active",
                       payor_name: "Blue Cross", start_date: Date.current - 2.years, end_date: Date.current - 1.year)
        ]

        service = CoverageSummaryService.new(coverages)
        summary = service.summarize

        assert_equal 3, summary.coverages.count
        assert_equal 1, summary.active_coverages.count
        assert_equal 1, summary.expired_coverages.count
        assert_equal 1, summary.exhausted_coverages.count
        assert summary.prc_eligible
      end

      test "summarize identifies primary payer" do
        coverages = [
          Coverage.new(patient_dfn: "12345", coverage_type: "medicare_a", status: "active",
                       start_date: Date.current - 1.year, end_date: Date.current + 1.year),
          Coverage.new(patient_dfn: "12345", coverage_type: "private_insurance", status: "active",
                       payor_name: "Blue Cross", start_date: Date.current - 1.year, end_date: Date.current + 1.year)
        ]

        service = CoverageSummaryService.new(coverages)
        summary = service.summarize

        assert_equal "Blue Cross", summary.primary_payer
        assert_includes summary.secondary_payers, "Medicare"
      end

      test "summarize authorization reason includes coordination when active coverage" do
        coverages = [
          Coverage.new(patient_dfn: "12345", coverage_type: "medicare_a", status: "active",
                       start_date: Date.current - 1.year, end_date: Date.current + 1.year)
        ]

        service = CoverageSummaryService.new(coverages)
        summary = service.summarize

        assert summary.authorization_reason.include?("coordination"),
          "Expected 'coordination' in reason: #{summary.authorization_reason}"
      end

      test "summarize authorization reason includes exhausted when all exhausted" do
        coverages = [
          Coverage.new(patient_dfn: "12345", coverage_type: "medicare_a", status: "exhausted")
        ]

        service = CoverageSummaryService.new(coverages)
        summary = service.summarize

        assert summary.authorization_reason.include?("exhausted"),
          "Expected 'exhausted' in reason: #{summary.authorization_reason}"
      end

      # =============================================================================
      # EDGE CASES
      # =============================================================================

      test "handles empty coverage list" do
        service = CoverageSummaryService.new([])
        summary = service.summarize

        assert_equal [], summary.coverages
        assert_equal [], summary.active_coverages
        assert summary.prc_eligible
        refute summary.requires_coordination
      end

      test "handles nil coverage list" do
        service = CoverageSummaryService.new(nil)
        summary = service.summarize

        assert_equal [], summary.coverages
        assert summary.prc_eligible
      end

      test "deduplicates same payor in hierarchy" do
        coverages = [
          Coverage.new(patient_dfn: "12345", coverage_type: "medicare_a", status: "active",
                       start_date: Date.current - 1.year, end_date: Date.current + 1.year),
          Coverage.new(patient_dfn: "12345", coverage_type: "medicare_b", status: "active",
                       start_date: Date.current - 1.year, end_date: Date.current + 1.year)
        ]

        service = CoverageSummaryService.new(coverages)
        hierarchy = service.determine_payer_hierarchy

        assert_equal 1, hierarchy.count { |p| p == "Medicare" }
      end
    end
  end
end
