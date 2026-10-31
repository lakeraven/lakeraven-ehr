# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # Issue #239 — Coverage records in PRC referral / alternate-resource workflow.
    #
    # Contract (panel round 1): On a PRC referral, payer order lists every active
    # alternate resource in COB priority, then IHS Purchased/Referred Care once at
    # the end; with no active coverage, PRC is primary. PRC appears only when
    # EligibilityService marks the patient prc_eligible. Outside a referral context,
    # payer summaries omit PRC.
    class CoverageWorkflowTest < ActiveSupport::TestCase
      PRC_PAYER = CoverageSummaryService::PRC_PAYER

      setup do
        @patient = Patient.new(
          dfn: 100,
          name: "DOE,JANE",
          sex: "F",
          tribal_enrollment_number: "EXNH-12345",
          service_area: "Anchorage",
          coverage_type: "Private Insurance/IHS"
        )

        @service_request = ServiceRequest.new(
          ien: 5001,
          patient_dfn: 100,
          requesting_provider_ien: 201,
          service_requested: "Cardiology Consult",
          reason_for_referral: "Chest pain workup not available at IHS facility",
          urgency: "ROUTINE",
          status: "draft"
        )
        patient = @patient
        @service_request.define_singleton_method(:patient) { patient }
        @service_request.define_singleton_method(:urgency_symbol) { :routine }

        @private_coverage = Coverage.new(
          patient_dfn: "100",
          coverage_type: "private_insurance",
          payor_name: "Blue Cross",
          plan_name: "PPO Gold",
          member_id: "BC-SYNTH-0001",
          status: "active",
          start_date: Date.current - 1.year,
          end_date: Date.current + 1.year
        )
      end

      test "referral eligibility summary lists private insurance primary and PRC last" do
        result = refresh_with_coverages([ @private_coverage ])

        summary = result.coverage_summary
        assert summary, "Expected coverage summary when referral has active private insurance"
        assert result.prc_eligible, "Expected eligible patient for PRC referral context"

        assert_equal "Blue Cross", summary.primary_payer
        assert_equal [ "Blue Cross", PRC_PAYER ], summary.payer_hierarchy
        assert_equal 1, summary.payer_hierarchy.count(PRC_PAYER)
      end

      test "referral Medicare and Medicaid active coverages list PRC last once" do
        coverages = [
          Coverage.new(patient_dfn: "100", coverage_type: "medicare_a", status: "active"),
          Coverage.new(patient_dfn: "100", coverage_type: "medicaid", status: "active")
        ]

        summary = refresh_with_coverages(coverages).coverage_summary

        assert_equal [ "Medicare", "Medicaid", PRC_PAYER ], summary.payer_hierarchy
      end

      test "PRC-ineligible patient referral coverage summary omits PRC from payer order" do
        ineligible_patient = Patient.new(
          dfn: 100,
          name: "DOE,JANE",
          sex: "F",
          tribal_enrollment_number: "INVALID",
          service_area: "Anchorage",
          coverage_type: "Private Insurance/IHS"
        )
        patient = ineligible_patient
        @service_request.define_singleton_method(:patient) { patient }

        result = PatientEligibilitySummaryService.refresh(
          patient: ineligible_patient,
          service_request: @service_request,
          coverages: [ @private_coverage ]
        )

        refute result.prc_eligible
        summary = result.coverage_summary
        refute_includes summary.payer_hierarchy, PRC_PAYER
        assert_equal [ "Blue Cross" ], summary.payer_hierarchy
      end

      test "refresh without service_request does not append PRC to payer hierarchy" do
        result = PatientEligibilitySummaryService.refresh(
          patient: @patient,
          coverages: [ @private_coverage ]
        )

        summary = result.coverage_summary
        assert_equal [ "Blue Cross" ], summary.payer_hierarchy
        refute_includes summary.payer_hierarchy, PRC_PAYER
      end

      test "alternate resource check is linked to the patient Coverage records used for the referral" do
        result = refresh_with_coverages([ @private_coverage ])

        check = result.alternate_resource_check
        assert check, "Expected alternate resource check on referral workflow result"

        linked = check.coverages
        assert_equal 1, linked.size
        assert_equal @private_coverage.member_id, linked.first.member_id
        assert_equal "Blue Cross", linked.first.payor_name
      end

      test "originated referral with active private coverage records primary and PRC payer order" do
        origination = ReferralOriginationService.new.originate(
          patient_dfn: @patient.dfn,
          provider_ien: 201,
          params: {
            service_requested: "Cardiology Consult",
            urgency: "ROUTINE",
            reason_for_referral: "Chest pain workup not available at IHS facility"
          }
        )

        assert origination.success?

        service_request = origination.service_request
        patient = @patient
        service_request.define_singleton_method(:patient) { patient }
        service_request.define_singleton_method(:urgency_symbol) { :routine }

        summary = PatientEligibilitySummaryService.refresh(
          patient: @patient,
          service_request: service_request,
          coverages: [ @private_coverage ]
        ).coverage_summary

        assert_equal "Blue Cross", summary.primary_payer
        assert_equal [ "Blue Cross", PRC_PAYER ], summary.payer_hierarchy
      end

      private

      def refresh_with_coverages(coverages)
        PatientEligibilitySummaryService.refresh(
          patient: @patient,
          service_request: @service_request,
          coverages: coverages
        )
      end
    end
  end
end
