# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class OrganizationsControllerTest < ActionDispatch::IntegrationTest
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

      test "GET /Organization/:ien returns FHIR Organization" do
        get "/lakeraven-ehr/Organization/1", headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Organization", body["resourceType"]
        assert_equal "1", body["id"]
        assert_equal "Alaska Native Medical Center", body["name"]
      end

      test "unknown Organization returns 404" do
        get "/lakeraven-ehr/Organization/99999", headers: @headers
        assert_response :not_found
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
      end

      test "Organization includes address" do
        get "/lakeraven-ehr/Organization/1", headers: @headers
        body = JSON.parse(response.body)
        addr = body["address"]&.first
        assert_equal "Anchorage", addr["city"]
        assert_equal "AK", addr["state"]
      end
    end
  end
end
