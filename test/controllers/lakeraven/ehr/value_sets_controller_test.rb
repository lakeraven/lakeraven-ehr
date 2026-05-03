# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ValueSetsControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_smart_auth
      end

      teardown do
        teardown_smart_auth
      end

      test "GET /ValueSet returns 200 with FHIR Bundle" do
        get "/lakeraven-ehr/ValueSet", headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
      end

      test "GET /ValueSet returns FHIR content type" do
        get "/lakeraven-ehr/ValueSet", headers: @headers
        assert_equal "application/fhir+json", response.media_type
      end

      test "GET /ValueSet requires auth" do
        get "/lakeraven-ehr/ValueSet"
        assert_response :unauthorized
      end

      test "GET /ValueSet returns searchset bundle" do
        get "/lakeraven-ehr/ValueSet", headers: @headers
        body = JSON.parse(response.body)
        assert_equal "searchset", body["type"]
      end

      test "GET /ValueSet/:id for nonexistent returns 404" do
        get "/lakeraven-ehr/ValueSet/nonexistent", headers: @headers
        assert_response :not_found
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
      end

      test "GET /ValueSet/:id/$expand for nonexistent returns 404" do
        get "/lakeraven-ehr/ValueSet/nonexistent/$expand", headers: @headers
        assert_response :not_found
      end

      test "token without ValueSet scope returns 403" do
        app = Doorkeeper::Application.create!(
          name: "scope-test", redirect_uri: "https://example.test/callback",
          scopes: "openid", confidential: true
        )
        token = Doorkeeper::AccessToken.create!(application: app, scopes: "openid", expires_in: 3600)
        get "/lakeraven-ehr/ValueSet",
          headers: { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
        assert_response :forbidden
      end

      test "expired token returns 401" do
        expired = Doorkeeper::AccessToken.create!(
          application: @oauth_app, scopes: "system/*.read", expires_in: -1
        )
        get "/lakeraven-ehr/ValueSet",
          headers: { "Authorization" => "Bearer #{expired.plaintext_token || expired.token}" }
        assert_response :unauthorized
      end

      test "401 response is OperationOutcome" do
        get "/lakeraven-ehr/ValueSet"
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
      end

      test "404 response includes not-found code" do
        get "/lakeraven-ehr/ValueSet/nonexistent", headers: @headers
        body = JSON.parse(response.body)
        assert_equal "not-found", body["issue"].first["code"]
      end

      test "FHIR content type on 404" do
        get "/lakeraven-ehr/ValueSet/nonexistent", headers: @headers
        assert_equal "application/fhir+json", response.media_type
      end
    end
  end
end
