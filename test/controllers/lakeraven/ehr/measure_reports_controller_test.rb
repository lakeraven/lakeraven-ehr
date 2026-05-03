# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class MeasureReportsControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_smart_auth
      end

      teardown do
        teardown_smart_auth
      end

      test "GET /MeasureReport returns 200 with FHIR Bundle" do
        get "/lakeraven-ehr/MeasureReport", headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
      end

      test "GET /MeasureReport returns FHIR content type" do
        get "/lakeraven-ehr/MeasureReport", headers: @headers
        assert_equal "application/fhir+json", response.media_type
      end

      test "GET /MeasureReport requires auth" do
        get "/lakeraven-ehr/MeasureReport"
        assert_response :unauthorized
      end

      test "GET /MeasureReport returns searchset bundle type" do
        get "/lakeraven-ehr/MeasureReport", headers: @headers
        body = JSON.parse(response.body)
        assert_equal "searchset", body["type"]
      end

      test "expired token returns 401" do
        expired = Doorkeeper::AccessToken.create!(
          application: @oauth_app, scopes: "system/*.read", expires_in: -1
        )
        get "/lakeraven-ehr/MeasureReport",
          headers: { "Authorization" => "Bearer #{expired.plaintext_token || expired.token}" }
        assert_response :unauthorized
      end

      test "401 response is OperationOutcome" do
        get "/lakeraven-ehr/MeasureReport"
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
      end

      test "token without MeasureReport scope returns 403" do
        app = Doorkeeper::Application.create!(
          name: "scope-test", redirect_uri: "https://example.test/callback",
          scopes: "openid", confidential: true
        )
        token = Doorkeeper::AccessToken.create!(application: app, scopes: "openid", expires_in: 3600)
        get "/lakeraven-ehr/MeasureReport",
          headers: { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
        assert_response :forbidden
      end
    end
  end
end
