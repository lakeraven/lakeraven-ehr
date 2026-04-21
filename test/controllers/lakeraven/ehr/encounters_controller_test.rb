# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class EncountersControllerTest < ActionDispatch::IntegrationTest
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

      test "GET /Encounter?patient=1 returns FHIR Bundle" do
        get "/lakeraven-ehr/Encounter", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
      end

      test "Encounter search without patient returns 400" do
        get "/lakeraven-ehr/Encounter", headers: @headers
        assert_response :bad_request
      end
    end
  end
end
