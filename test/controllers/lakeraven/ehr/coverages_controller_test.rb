# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class CoveragesControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        # These endpoints CHANGE STATE, so they need a write scope. They used
        # to pass on the default read-only token because the base filter
        # called can_read? for every verb (review finding H4).
        setup_smart_auth(scopes: "system/*.read system/*.write")
      end

      teardown do
        teardown_smart_auth
      end

      # -- POST /CoverageEligibilityRequest (trigger check) -------------------

      test "POST triggers eligibility check and returns response" do
        post "/lakeraven-ehr/CoverageEligibilityRequest",
             params: { patient_dfn: "1", coverage_type: "medicaid" },
             headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "CoverageEligibilityResponse", body["resourceType"]
      end

      test "POST with invalid request returns 422" do
        post "/lakeraven-ehr/CoverageEligibilityRequest",
             params: { coverage_type: "medicaid" },
             headers: @headers
        assert_response :unprocessable_content
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
      end

      test "POST requires auth" do
        post "/lakeraven-ehr/CoverageEligibilityRequest",
             params: { patient_dfn: "1", coverage_type: "medicaid" }
        assert_response :unauthorized
      end
    end
  end
end
