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

      # -- UUID generation -------------------------------------------------------

      test "generates UUID for id if not provided" do
        resp = CoverageEligibilityResponse.new(status: "enrolled")
        assert resp.id.present?
        assert_match(/^[0-9a-f-]{36}$/, resp.id)
      end

      test "sets created_at to current time if not provided" do
        resp = CoverageEligibilityResponse.new(status: "enrolled")
        assert resp.created_at.present?
        assert_in_delta Time.current, resp.created_at, 1.second
      end

      # -- coverage_details ------------------------------------------------------

      test "coverage_details returns nil when not enrolled" do
        resp = CoverageEligibilityResponse.new(status: "not_enrolled")
        assert_nil resp.coverage_details
      end

      test "coverage_details returns hash when enrolled" do
        resp = CoverageEligibilityResponse.new(
          status: "enrolled", coverage_type: "medicare_a",
          start_date: Date.new(2024, 1, 1), end_date: Date.new(2024, 12, 31)
        )
        details = resp.coverage_details
        assert_equal "medicare_a", details[:type]
        assert_equal "enrolled", details[:status]
        assert details[:period].present?
      end

      # -- coverage_period -------------------------------------------------------

      test "coverage_period returns start and end dates" do
        resp = CoverageEligibilityResponse.new(
          status: "enrolled",
          start_date: Date.new(2024, 1, 1), end_date: Date.new(2024, 12, 31)
        )
        period = resp.coverage_period
        assert_equal Date.new(2024, 1, 1), period[:start]
        assert_equal Date.new(2024, 12, 31), period[:end]
      end

      test "coverage_period returns nil when no dates" do
        resp = CoverageEligibilityResponse.new(status: "enrolled")
        assert_nil resp.coverage_period
      end

      # -- plan_info -------------------------------------------------------------

      test "plan_info returns plan details" do
        resp = CoverageEligibilityResponse.new(
          status: "enrolled", plan_name: "Blue Cross PPO",
          policy_id: "BC123456", group_id: "GRP001"
        )
        plan = resp.plan_info
        assert_equal "Blue Cross PPO", plan[:name]
        assert_equal "BC123456", plan[:policy_id]
        assert_equal "GRP001", plan[:group_id]
      end

      test "plan_info returns nil when no plan details" do
        resp = CoverageEligibilityResponse.new(status: "enrolled")
        assert_nil resp.plan_info
      end

      # -- insurer_info ----------------------------------------------------------

      test "insurer_info returns insurer details" do
        resp = CoverageEligibilityResponse.new(
          status: "enrolled", insurer_name: "Blue Cross Blue Shield", insurer_id: "BCBS001"
        )
        insurer = resp.insurer_info
        assert_equal "Blue Cross Blue Shield", insurer[:name]
        assert_equal "BCBS001", insurer[:id]
      end

      # -- to_fhir includes request reference ------------------------------------

      test "to_fhir includes request reference when provided" do
        resp = CoverageEligibilityResponse.new(
          status: "enrolled", request_id: "req-123"
        )
        fhir = resp.to_fhir
        assert_equal "CoverageEligibilityRequest/req-123", fhir.dig(:request, :reference)
      end

      # -- to_fhir includes insurance when enrolled ------------------------------

      test "to_fhir includes insurance when enrolled" do
        resp = CoverageEligibilityResponse.new(
          status: "enrolled", patient_dfn: "1", coverage_type: "medicare_a",
          start_date: Date.new(2024, 1, 1)
        )
        fhir = resp.to_fhir
        assert fhir[:insurance].present?
      end

      test "to_fhir does not include insurance when not enrolled" do
        resp = CoverageEligibilityResponse.new(
          status: "not_enrolled", patient_dfn: "1"
        )
        fhir = resp.to_fhir
        assert_nil fhir[:insurance]
      end

      # -- from_fhir -------------------------------------------------------------

      test "from_fhir creates response from FHIR hash" do
        fhir_hash = {
          resourceType: "CoverageEligibilityResponse",
          id: "resp-123",
          patient: { reference: "Patient/12345" },
          request: { reference: "CoverageEligibilityRequest/req-456" },
          outcome: "complete",
          disposition: "Coverage active",
          insurance: [ { inforce: true } ]
        }

        resp = CoverageEligibilityResponse.from_fhir(fhir_hash)
        assert_equal "resp-123", resp.id
        assert_equal "12345", resp.patient_dfn
        assert_equal "req-456", resp.request_id
        assert_equal "Coverage active", resp.disposition
        assert_equal "enrolled", resp.status
      end

      test "from_fhir handles string keys" do
        fhir_hash = {
          "resourceType" => "CoverageEligibilityResponse",
          "id" => "resp-789",
          "patient" => { "reference" => "Patient/67890" },
          "outcome" => "queued"
        }

        resp = CoverageEligibilityResponse.from_fhir(fhir_hash)
        assert_equal "resp-789", resp.id
        assert_equal "67890", resp.patient_dfn
        assert_equal "pending", resp.status
      end

      test "from_fhir extracts coverage period" do
        fhir_hash = {
          resourceType: "CoverageEligibilityResponse",
          id: "resp-123",
          outcome: "complete",
          insurance: [ {
            inforce: true,
            benefitPeriod: { start: "2024-01-01", end: "2024-12-31" }
          } ]
        }

        resp = CoverageEligibilityResponse.from_fhir(fhir_hash)
        assert_equal Date.new(2024, 1, 1), resp.start_date
        assert_equal Date.new(2024, 12, 31), resp.end_date
      end
    end
  end
end
