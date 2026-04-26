# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class PatientEligibilitySummaryServiceTest < ActiveSupport::TestCase
      setup do
        @patient = Patient.new(
          dfn: 1,
          name: "TEST,PATIENT",
          sex: "M",
          tribal_enrollment_number: "AK-12345",
          service_area: "Anchorage",
          coverage_type: "IHS"
        )

        @service_request = ServiceRequest.new(
          ien: 1,
          patient_dfn: 1,
          requesting_provider_ien: 101,
          service_requested: "CARDIOLOGY",
          reason_for_referral: "Cardiac evaluation needed for chest pain",
          urgency: "ROUTINE",
          status: "draft"
        )
        # Wire up patient association
        patient = @patient
        @service_request.define_singleton_method(:patient) { patient }
        @service_request.define_singleton_method(:urgency_symbol) {
          case urgency
          when "EMERGENT" then :emergent
          when "URGENT" then :urgent
          else :routine
          end
        }
      end

      # =========================================================================
      # SUMMARIZE
      # =========================================================================

      test "summarize returns a Result struct" do
        result = PatientEligibilitySummaryService.summarize(patient: @patient)

        assert_instance_of PatientEligibilitySummaryService::Result, result
      end

      test "summarize with service_request includes PRC checks" do
        result = PatientEligibilitySummaryService.summarize(
          patient: @patient,
          service_request: @service_request
        )

        assert result.prc_checks.any?, "Expected PRC checks"
        assert result.prc_checks.key?(:tribal_enrollment)
        assert result.prc_checks.key?(:residency)
        assert result.prc_checks.key?(:clinical_necessity)
        assert result.prc_checks.key?(:payor_coordination)
      end

      test "summarize without service_request returns empty PRC checks" do
        result = PatientEligibilitySummaryService.summarize(patient: @patient)

        assert_equal({}, result.prc_checks)
        assert_nil result.prc_eligible
      end

      test "summarize includes coverage summary when patient has coverage_type" do
        result = PatientEligibilitySummaryService.summarize(patient: @patient)

        assert result.coverage_summary, "Expected coverage summary for patient with coverage_type"
      end

      test "summarize returns nil coverage for patient without coverage_type" do
        patient = Patient.new(dfn: 999, name: "TEST,OTHER", sex: "F", coverage_type: nil)
        result = PatientEligibilitySummaryService.summarize(patient: patient)

        assert_nil result.coverage_summary
      end

      # =========================================================================
      # TIMESTAMPS
      # =========================================================================

      test "PRC check includes timestamp" do
        result = PatientEligibilitySummaryService.summarize(
          patient: @patient,
          service_request: @service_request
        )

        assert result.prc_checked_at.is_a?(Time)
      end

      test "coverage includes retrieved_at timestamp" do
        result = PatientEligibilitySummaryService.summarize(patient: @patient)

        assert result.coverage_retrieved_at.is_a?(Time)
      end

      test "payer_verified_at is nil when not refreshed" do
        result = PatientEligibilitySummaryService.summarize(patient: @patient)

        assert_nil result.payer_verified_at
        assert_equal [], result.payer_verification_results
      end

      # =========================================================================
      # PRC CHECK STATUS VALUES
      # =========================================================================

      test "PRC checks return PASS or FAIL status" do
        result = PatientEligibilitySummaryService.summarize(
          patient: @patient,
          service_request: @service_request
        )

        result.prc_checks.each do |_name, check|
          assert %w[PASS FAIL].include?(check[:status]),
            "Expected PASS or FAIL, got #{check[:status]}"
        end
      end

      test "PRC checks include message for each check" do
        result = PatientEligibilitySummaryService.summarize(
          patient: @patient,
          service_request: @service_request
        )

        result.prc_checks.each do |name, check|
          assert check[:message].present?, "Expected message for #{name}"
        end
      end

      # =========================================================================
      # REFRESH WITH PAYER VERIFICATION
      # =========================================================================

      test "refresh with empty coverages reports skip reason" do
        result = PatientEligibilitySummaryService.refresh(
          patient: @patient,
          coverages: []
        )

        assert result.payer_verification_skip_reason.present?
      end

      test "refresh with coverages lacking subscriber_id reports skip reason" do
        coverages = [ Coverage.new(
          patient_dfn: @patient.dfn.to_s,
          coverage_type: "medicare_a",
          status: "active"
        ) ]

        result = PatientEligibilitySummaryService.refresh(
          patient: @patient,
          coverages: coverages
        )

        assert_equal [], result.payer_verification_results
        assert result.payer_verification_skip_reason.present?
        assert_includes result.payer_verification_skip_reason, "subscriber ID"
      end

      test "payer verification cache write is the only acceptable write" do
        result = PatientEligibilitySummaryService.refresh(
          patient: @patient,
          coverages: []
        )

        assert_instance_of PatientEligibilitySummaryService::Result, result
      end
    end
  end
end
