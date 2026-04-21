# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class CoverageEligibilityRequestTest < ActiveSupport::TestCase
      test "creates with required attributes" do
        req = CoverageEligibilityRequest.new(
          patient_dfn: "1",
          coverage_type: "medicaid",
          purpose: "benefits"
        )
        assert req.valid?
      end

      test "validates patient_dfn presence" do
        req = CoverageEligibilityRequest.new(coverage_type: "medicaid", purpose: "benefits")
        assert_not req.valid?
        assert_includes req.errors[:patient_dfn], "can't be blank"
      end

      test "validates coverage_type inclusion" do
        req = CoverageEligibilityRequest.new(patient_dfn: "1", coverage_type: "bogus", purpose: "benefits")
        assert_not req.valid?
      end

      test "validates purpose inclusion" do
        req = CoverageEligibilityRequest.new(patient_dfn: "1", coverage_type: "medicaid", purpose: "bogus")
        assert_not req.valid?
      end

      test "defaults purpose to benefits" do
        req = CoverageEligibilityRequest.new(patient_dfn: "1", coverage_type: "medicaid")
        assert_equal "benefits", req.purpose
      end

      test "defaults service_date to today" do
        req = CoverageEligibilityRequest.new(patient_dfn: "1", coverage_type: "medicaid")
        assert_equal Date.current, req.service_date
      end

      test "accepts service_type_codes" do
        req = CoverageEligibilityRequest.new(
          patient_dfn: "1", coverage_type: "medicaid",
          service_type_codes: %w[30 MH]
        )
        assert_equal %w[30 MH], req.service_type_codes
      end

      # -- FHIR serialization --------------------------------------------------

      test "to_fhir returns CoverageEligibilityRequest resource" do
        req = CoverageEligibilityRequest.new(
          patient_dfn: "1", coverage_type: "medicaid",
          provider_npi: "1234567890", service_date: Date.new(2025, 6, 1)
        )
        fhir = req.to_fhir

        assert_equal "CoverageEligibilityRequest", fhir[:resourceType]
        assert_equal "active", fhir[:status]
        assert_equal "benefits", fhir[:purpose]
        assert_equal "Patient/1", fhir.dig(:patient, :reference)
        assert_equal "2025-06-01", fhir[:servicedDate]
      end
    end
  end
end
