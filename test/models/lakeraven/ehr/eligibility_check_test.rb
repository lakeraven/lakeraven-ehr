# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class EligibilityCheckTest < ActiveSupport::TestCase
      setup do
        @request = CoverageEligibilityRequest.new(
          patient_dfn: "1", coverage_type: "medicaid",
          provider_npi: "1234567890"
        )
      end

      # -- Mock adapter returns enrolled by default --------------------------

      test "check returns CoverageEligibilityResponse" do
        result = EligibilityCheck.call(@request)
        assert_kind_of CoverageEligibilityResponse, result
      end

      test "mock adapter returns enrolled status" do
        result = EligibilityCheck.call(@request)
        assert result.enrolled?
        assert_equal "medicaid", result.coverage_type
        assert_equal "1", result.patient_dfn
      end

      # -- Adapter configuration ---------------------------------------------

      test "uses configured adapter" do
        custom_adapter = ->(_req) {
          CoverageEligibilityResponse.new(
            patient_dfn: "1", coverage_type: "medicaid", status: "not_enrolled"
          )
        }

        original = Lakeraven::EHR.configuration.eligibility_adapter
        Lakeraven::EHR.configuration.eligibility_adapter = custom_adapter

        result = EligibilityCheck.call(@request)
        assert result.not_enrolled?
      ensure
        Lakeraven::EHR.configuration.eligibility_adapter = original
      end

      # -- Validation ---------------------------------------------------------

      test "raises on invalid request" do
        bad_request = CoverageEligibilityRequest.new(patient_dfn: nil)
        assert_raises(EligibilityCheck::InvalidRequestError) do
          EligibilityCheck.call(bad_request)
        end
      end
    end
  end
end
