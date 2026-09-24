# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class EncountersControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_smart_auth
      end

      teardown do
        teardown_smart_auth
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

      test "entries have correct resourceType" do
        get "/lakeraven-ehr/Encounter", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        body["entry"]&.each do |entry|
          assert_equal "Encounter", entry.dig("resource", "resourceType")
        end
      end

      test "returns FHIR JSON content type" do
        get "/lakeraven-ehr/Encounter", params: { patient: "1" }, headers: @headers
        assert_equal "application/fhir+json", response.media_type
      end

      test "accepts Patient/ prefix in patient param" do
        get "/lakeraven-ehr/Encounter", params: { patient: "Patient/1" }, headers: @headers
        assert_response :ok
      end

      test "requires auth" do
        get "/lakeraven-ehr/Encounter", params: { patient: "1" }
        assert_response :unauthorized
      end

      # -- Expired/revoked/invalid token auth ------------------------------------

      test "expired token returns 401" do
        expired = Doorkeeper::AccessToken.create!(
          application: @oauth_app, scopes: "system/*.read",
          expires_in: -1
        )
        get "/lakeraven-ehr/Encounter", params: { patient: "1" },
          headers: { "Authorization" => "Bearer #{expired.plaintext_token || expired.token}" }
        assert_response :unauthorized
      end

      test "revoked token returns 401" do
        revoked = Doorkeeper::AccessToken.create!(
          application: @oauth_app, scopes: "system/*.read", expires_in: 3600
        )
        revoked.revoke
        get "/lakeraven-ehr/Encounter", params: { patient: "1" },
          headers: { "Authorization" => "Bearer #{revoked.plaintext_token || revoked.token}" }
        assert_response :unauthorized
      end

      test "invalid token returns 401" do
        get "/lakeraven-ehr/Encounter", params: { patient: "1" },
          headers: { "Authorization" => "Bearer totally_bogus_token" }
        assert_response :unauthorized
      end

      # -- Scope enforcement -----------------------------------------------------

      test "token without Encounter read scope returns 403" do
        app = Doorkeeper::Application.create!(
          name: "scope-test", redirect_uri: "https://example.test/callback",
          scopes: "openid", confidential: true
        )
        token = Doorkeeper::AccessToken.create!(application: app, scopes: "openid", expires_in: 3600)
        get "/lakeraven-ehr/Encounter", params: { patient: "1" },
          headers: { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
        assert_response :forbidden
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "forbidden", body["issue"].first["code"]
      end

      test "system/Encounter.read scope grants access" do
        app = Doorkeeper::Application.create!(
          name: "encounter-read", redirect_uri: "https://example.test/callback",
          scopes: "system/Encounter.read", confidential: true
        )
        token = Doorkeeper::AccessToken.create!(application: app, scopes: "system/Encounter.read", expires_in: 3600)
        get "/lakeraven-ehr/Encounter", params: { patient: "1" },
          headers: { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
        assert_response :ok
      end

      # -- Error response structure ----------------------------------------------

      test "401 response is OperationOutcome" do
        get "/lakeraven-ehr/Encounter", params: { patient: "1" }
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "login", body["issue"].first["code"]
      end

      test "400 response is OperationOutcome with required code" do
        get "/lakeraven-ehr/Encounter", headers: @headers
        assert_response :bad_request
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "required", body["issue"].first["code"]
      end

      # -- Entry resourceType validation -----------------------------------------

      test "all bundle entries have Encounter resourceType" do
        get "/lakeraven-ehr/Encounter", params: { patient: "1" }, headers: @headers
        body = JSON.parse(response.body)
        body["entry"]&.each do |entry|
          assert_equal "Encounter", entry.dig("resource", "resourceType"),
            "Expected all entries to be Encounter resources"
        end
      end

      test "bundle type is searchset" do
        get "/lakeraven-ehr/Encounter", params: { patient: "1" }, headers: @headers
        body = JSON.parse(response.body)
        assert_equal "searchset", body["type"]
      end

      test "bundle includes total count" do
        get "/lakeraven-ehr/Encounter", params: { patient: "1" }, headers: @headers
        body = JSON.parse(response.body)
        assert body.key?("total"), "Bundle should include total count"
      end

      test "FHIR content type on error responses" do
        get "/lakeraven-ehr/Encounter", headers: @headers
        assert_equal "application/fhir+json", response.media_type
      end

      test "FHIR content type on 401 responses" do
        get "/lakeraven-ehr/Encounter", params: { patient: "1" }
        assert_equal "application/fhir+json", response.media_type
      end
    end
  end
end
