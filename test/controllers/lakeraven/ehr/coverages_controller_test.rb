# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class CoveragesControllerTest < ActionDispatch::IntegrationTest
      setup do
        @oauth_app = Doorkeeper::Application.create!(
          name: "test", redirect_uri: "https://example.test/callback",
          scopes: "system/*.read", confidential: true
        )
        token = Doorkeeper::AccessToken.create!(
          application: @oauth_app, scopes: "system/*.read", expires_in: 3600
        )
        @headers = { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
      end

      teardown do
        Doorkeeper::AccessToken.delete_all
        Doorkeeper::Application.delete_all
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
