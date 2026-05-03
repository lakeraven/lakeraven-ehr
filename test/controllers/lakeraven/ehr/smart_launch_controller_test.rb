# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class SmartLaunchControllerTest < ActionDispatch::IntegrationTest
      test "GET /smart/launch without params returns 400" do
        get "/lakeraven-ehr/smart/launch"
        assert_response :bad_request
        body = JSON.parse(response.body)
        assert_equal "invalid_request", body["error"]
      end

      test "GET /smart/launch with launch and iss returns 200" do
        get "/lakeraven-ehr/smart/launch",
          params: { launch: "abc123", iss: "https://ehr.example.com" }
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "abc123", body["launch"]
        assert body["authorization_endpoint"].present?
        assert body["token_endpoint"].present?
      end

      test "GET /smart/launch with known client_id redirects to authorize" do
        app = Doorkeeper::Application.create!(
          name: "smart-test", redirect_uri: "https://app.test/callback",
          scopes: "launch patient/*.read", confidential: true
        )
        get "/lakeraven-ehr/smart/launch",
          params: { launch: "abc123", iss: "https://ehr.example.com", client_id: app.uid }
        assert_response :redirect
        assert response.location.include?("oauth/authorize")
        assert response.location.include?(app.uid)
        app.destroy!
      end

      test "GET /smart/launch with unknown client_id returns launch context" do
        get "/lakeraven-ehr/smart/launch",
          params: { launch: "abc123", iss: "https://ehr.example.com", client_id: "unknown" }
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "abc123", body["launch"]
      end

      test "launch response includes authorization_endpoint" do
        get "/lakeraven-ehr/smart/launch",
          params: { launch: "abc123", iss: "https://ehr.example.com" }
        body = JSON.parse(response.body)
        assert body["authorization_endpoint"].end_with?("oauth/authorize")
      end

      test "launch response includes token_endpoint" do
        get "/lakeraven-ehr/smart/launch",
          params: { launch: "abc123", iss: "https://ehr.example.com" }
        body = JSON.parse(response.body)
        assert body["token_endpoint"].end_with?("oauth/token")
      end

      test "missing launch param returns 400" do
        get "/lakeraven-ehr/smart/launch", params: { iss: "https://ehr.example.com" }
        assert_response :bad_request
      end

      test "missing iss param returns 400" do
        get "/lakeraven-ehr/smart/launch", params: { launch: "abc123" }
        assert_response :bad_request
      end
    end
  end
end
