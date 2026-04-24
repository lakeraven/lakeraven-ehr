# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class CoverageEligibilityResponseTest < ActiveSupport::TestCase
      test "creates with enrolled status" do
        resp = CoverageEligibilityResponse.new(
          patient_dfn: "1", coverage_type: "medicaid", status: "enrolled",
          plan_name: "State Medicaid", insurer_name: "State of Alaska"
        )
        assert resp.enrolled?
        assert resp.active_coverage?
      end

      test "not_enrolled status" do
        resp = CoverageEligibilityResponse.new(
          patient_dfn: "1", coverage_type: "medicaid", status: "not_enrolled"
        )
        assert resp.not_enrolled?
        assert_not resp.active_coverage?
      end

      test "error status" do
        resp = CoverageEligibilityResponse.new(
          patient_dfn: "1", coverage_type: "medicaid", status: "error",
          error_code: "75", error_message: "Member details don't match"
        )
        assert resp.error?
        assert_not resp.active_coverage?
      end

      test "validates status inclusion" do
        resp = CoverageEligibilityResponse.new(
          patient_dfn: "1", coverage_type: "medicaid", status: "bogus"
        )
        assert_not resp.valid?
      end

      test "within_coverage_period? checks dates" do
        resp = CoverageEligibilityResponse.new(
          patient_dfn: "1", coverage_type: "medicaid", status: "enrolled",
          start_date: 1.year.ago, end_date: 1.year.from_now
        )
        assert resp.within_coverage_period?
      end

      test "within_coverage_period? false when expired" do
        resp = CoverageEligibilityResponse.new(
          patient_dfn: "1", coverage_type: "medicaid", status: "enrolled",
          start_date: 2.years.ago, end_date: 1.year.ago
        )
        assert_not resp.within_coverage_period?
      end

      test "final? for terminal statuses" do
        assert CoverageEligibilityResponse.new(status: "enrolled").final?
        assert CoverageEligibilityResponse.new(status: "not_enrolled").final?
        assert CoverageEligibilityResponse.new(status: "denied").final?
        assert_not CoverageEligibilityResponse.new(status: "pending").final?
      end

      # -- AAA error codes (from Stedi article) --------------------------------

      test "transient_error? for retryable codes" do
        resp = CoverageEligibilityResponse.new(status: "error", error_code: "42")
        assert resp.transient_error?

        resp2 = CoverageEligibilityResponse.new(status: "error", error_code: "80")
        assert resp2.transient_error?
      end

      test "transient_error? false for non-retryable codes" do
        resp = CoverageEligibilityResponse.new(status: "error", error_code: "75")
        assert_not resp.transient_error?
      end

      # -- FHIR serialization --------------------------------------------------

      test "to_fhir returns CoverageEligibilityResponse resource" do
        resp = CoverageEligibilityResponse.new(
          patient_dfn: "1", coverage_type: "medicaid", status: "enrolled",
          plan_name: "State Medicaid", insurer_name: "State of Alaska",
          start_date: Date.new(2025, 1, 1), end_date: Date.new(2025, 12, 31)
        )
        fhir = resp.to_fhir

        assert_equal "CoverageEligibilityResponse", fhir[:resourceType]
        assert_equal "active", fhir[:status]
        assert_equal "complete", fhir[:outcome]
        assert_equal "Patient/1", fhir.dig(:patient, :reference)
      end

      test "to_fhir maps error status to error outcome" do
        resp = CoverageEligibilityResponse.new(
          patient_dfn: "1", coverage_type: "medicaid", status: "error",
          error_code: "75", error_message: "Member mismatch"
        )
        fhir = resp.to_fhir

        assert_equal "error", fhir[:outcome]
      end

      # -- additional status predicates ----------------------------------------

      test "pending? for pending status" do
        assert CoverageEligibilityResponse.new(status: "pending").pending?
      end

      test "denied? for denied status" do
        assert CoverageEligibilityResponse.new(status: "denied").denied?
      end

      test "exhausted? for exhausted status" do
        assert CoverageEligibilityResponse.new(status: "exhausted").exhausted?
      end

      test "accepts all valid statuses" do
        %w[enrolled not_enrolled pending denied exhausted error].each do |status|
          resp = CoverageEligibilityResponse.new(
            patient_dfn: "1", coverage_type: "medicaid", status: status
          )
          assert resp.valid?, "Expected #{status} to be valid"
        end
      end

      # -- coverage period edge cases ------------------------------------------

      test "within_coverage_period? true when no dates" do
        resp = CoverageEligibilityResponse.new(
          patient_dfn: "1", status: "enrolled"
        )
        assert resp.within_coverage_period?
      end

      test "within_coverage_period? true when only start_date" do
        resp = CoverageEligibilityResponse.new(
          patient_dfn: "1", status: "enrolled",
          start_date: 1.year.ago
        )
        assert resp.within_coverage_period?
      end

      # -- active_coverage? combines status and period -------------------------

      test "active_coverage? false when enrolled but expired" do
        resp = CoverageEligibilityResponse.new(
          patient_dfn: "1", status: "enrolled",
          start_date: 2.years.ago, end_date: 1.year.ago
        )
        assert_not resp.active_coverage?
      end

      test "active_coverage? true when enrolled and current" do
        resp = CoverageEligibilityResponse.new(
          patient_dfn: "1", status: "enrolled",
          start_date: 1.year.ago, end_date: 1.year.from_now
        )
        assert resp.active_coverage?
      end

      # -- FHIR serialization details ------------------------------------------

      test "to_fhir includes insurer reference" do
        resp = CoverageEligibilityResponse.new(
          patient_dfn: "1", coverage_type: "medicaid", status: "enrolled",
          insurer_name: "State of Alaska"
        )
        fhir = resp.to_fhir
        assert fhir[:insurer].present?
      end

      test "to_fhir includes coverage period" do
        resp = CoverageEligibilityResponse.new(
          patient_dfn: "1", coverage_type: "medicaid", status: "enrolled",
          start_date: Date.new(2025, 1, 1), end_date: Date.new(2025, 12, 31)
        )
        fhir = resp.to_fhir
        # Period should be included in insurance or servicedPeriod
        assert_equal "CoverageEligibilityResponse", fhir[:resourceType]
      end

      test "to_fhir for not_enrolled maps outcome to complete" do
        resp = CoverageEligibilityResponse.new(
          patient_dfn: "1", coverage_type: "medicaid", status: "not_enrolled"
        )
        fhir = resp.to_fhir
        assert_equal "complete", fhir[:outcome]
      end
    end
  end
end
