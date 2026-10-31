# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # Issue #239 — Coverage records in PRC referral / alternate-resource workflow.
    class CoverageWorkflowTest < ActiveSupport::TestCase
      PRC_SECONDARY_LABEL = "IHS Purchased/Referred Care"

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

      test "referral eligibility summary lists private insurance primary and PRC secondary" do
        result = PatientEligibilitySummaryService.refresh(
          patient: @patient,
          service_request: @service_request,
          coverages: [ @private_coverage ]
        )

        summary = result.coverage_summary
        assert summary, "Expected coverage summary when referral has active private insurance"

        assert_equal "Blue Cross", summary.primary_payer
        assert_includes summary.secondary_payers, PRC_SECONDARY_LABEL
      end

      test "alternate resource check is linked to the patient Coverage records used for the referral" do
        result = PatientEligibilitySummaryService.refresh(
          patient: @patient,
          service_request: @service_request,
          coverages: [ @private_coverage ]
        )

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
        assert_includes summary.secondary_payers, PRC_SECONDARY_LABEL
      end
    end
  end
end
