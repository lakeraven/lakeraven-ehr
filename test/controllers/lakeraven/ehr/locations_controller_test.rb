# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class LocationsControllerTest < ActionDispatch::IntegrationTest
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

      test "GET /Location/:ien returns FHIR Location" do
        get "/lakeraven-ehr/Location/1", headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Location", body["resourceType"]
        assert_equal "1", body["id"]
        assert_equal "Primary Care Clinic", body["name"]
      end

      test "unknown Location returns 404" do
        get "/lakeraven-ehr/Location/99999", headers: @headers
        assert_response :not_found
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
      end
    end
  end
end
