# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class SmartAuthTest < ActionDispatch::IntegrationTest
      setup do
        @oauth_app = Doorkeeper::Application.create!(
          name: "test client",
          redirect_uri: "https://example.test/callback",
          scopes: "system/Patient.read patient/Patient.read",
          confidential: true
        )
      end

      teardown do
        Doorkeeper::AccessToken.delete_all
        Doorkeeper::Application.delete_all
      end

      def issue_token(scopes: "system/Patient.read", patient: nil)
        Doorkeeper::AccessToken.create!(
          application: @oauth_app,
          resource_owner_id: patient,
          scopes: scopes,
          expires_in: 3600
        )
      end

      def auth_headers(scopes: "system/Patient.read", patient: nil)
        token = issue_token(scopes: scopes, patient: patient)
        plaintext = token.plaintext_token || token.token
        { "Authorization" => "Bearer #{plaintext}" }
      end

      # -- No token → 401 -------------------------------------------------------

      test "request without Bearer token returns 401 OperationOutcome" do
        get "/lakeraven-ehr/Patient/1"
        assert_response :unauthorized
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "login", body["issue"].first["code"]
      end

      # -- Invalid token → 401 ---------------------------------------------------

      test "request with invalid token returns 401" do
        get "/lakeraven-ehr/Patient/1", headers: { "Authorization" => "Bearer invalid_token" }
        assert_response :unauthorized
      end

      # -- Valid token, wrong scope → 403 ----------------------------------------

      test "token without Patient read scope returns 403" do
        get "/lakeraven-ehr/Patient/1", headers: auth_headers(scopes: "openid")
        assert_response :forbidden
        body = JSON.parse(response.body)
        assert_equal "forbidden", body["issue"].first["code"]
      end

      # -- Valid token, correct scope → 200 --------------------------------------

      test "system/Patient.read scope grants access" do
        get "/lakeraven-ehr/Patient/1", headers: auth_headers(scopes: "system/Patient.read")
        assert_response :ok
      end

      test "user/Patient.read scope grants access" do
        get "/lakeraven-ehr/Patient/1", headers: auth_headers(scopes: "user/Patient.read")
        assert_response :ok
      end

      test "patient/Patient.read with matching bound patient grants access" do
        get "/lakeraven-ehr/Patient/1", headers: auth_headers(scopes: "patient/Patient.read", patient: "1")
        assert_response :ok
      end

      # -- Patient context enforcement -------------------------------------------

      test "patient/Patient.read with mismatched patient returns 403" do
        get "/lakeraven-ehr/Patient/1", headers: auth_headers(scopes: "patient/Patient.read", patient: "999")
        assert_response :forbidden
      end

      test "patient/Patient.read with no bound patient returns 403" do
        get "/lakeraven-ehr/Patient/1", headers: auth_headers(scopes: "patient/Patient.read", patient: nil)
        assert_response :forbidden
      end

      # -- Search also requires auth ---------------------------------------------

      test "search without token returns 401" do
        get "/lakeraven-ehr/Patient", params: { name: "Anderson" }
        assert_response :unauthorized
      end

      test "search with valid token returns 200" do
        get "/lakeraven-ehr/Patient", params: { name: "Anderson" }, headers: auth_headers
        assert_response :ok
      end

      # -- Practitioner endpoint auth --------------------------------------------

      test "Practitioner endpoint without token returns 401" do
        get "/lakeraven-ehr/Practitioner/101"
        assert_response :unauthorized
      end

      test "Practitioner endpoint with system/Practitioner.read returns 200" do
        get "/lakeraven-ehr/Practitioner/101", headers: auth_headers(scopes: "system/Practitioner.read")
        assert_response :ok
      end
    end
  end
end
