# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class AuditEventsControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_smart_auth
      end

      teardown do
        teardown_smart_auth
      end

      test "GET /AuditEvent returns 200 with FHIR Bundle" do
        get "/lakeraven-ehr/AuditEvent", headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
      end

      test "GET /AuditEvent returns FHIR content type" do
        get "/lakeraven-ehr/AuditEvent", headers: @headers
        assert_equal "application/fhir+json", response.media_type
      end

      test "GET /AuditEvent requires auth" do
        get "/lakeraven-ehr/AuditEvent"
        assert_response :unauthorized
      end

      test "GET /AuditEvent returns searchset bundle" do
        get "/lakeraven-ehr/AuditEvent", headers: @headers
        body = JSON.parse(response.body)
        assert_equal "searchset", body["type"]
      end

      test "GET /AuditEvent/:id for nonexistent returns 404" do
        get "/lakeraven-ehr/AuditEvent/99999", headers: @headers
        assert_response :not_found
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
      end

      test "GET /AuditEvent/:id returns FHIR AuditEvent when found" do
        event = AuditEvent.create!(
          event_type: "rest", action: "R", outcome: "0",
          entity_type: "Patient", entity_identifier: "1"
        )
        get "/lakeraven-ehr/AuditEvent/#{event.id}", headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "AuditEvent", body["resourceType"]
      end

      test "token without AuditEvent scope returns 403" do
        app = Doorkeeper::Application.create!(
          name: "scope-test", redirect_uri: "https://example.test/callback",
          scopes: "openid", confidential: true
        )
        token = Doorkeeper::AccessToken.create!(application: app, scopes: "openid", expires_in: 3600)
        get "/lakeraven-ehr/AuditEvent",
          headers: { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
        assert_response :forbidden
      end

      test "expired token returns 401" do
        expired = Doorkeeper::AccessToken.create!(
          application: @oauth_app, scopes: "system/*.read", expires_in: -1
        )
        get "/lakeraven-ehr/AuditEvent",
          headers: { "Authorization" => "Bearer #{expired.plaintext_token || expired.token}" }
        assert_response :unauthorized
      end

      test "401 response is OperationOutcome" do
        get "/lakeraven-ehr/AuditEvent"
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
      end

      test "FHIR content type on 404 responses" do
        get "/lakeraven-ehr/AuditEvent/99999", headers: @headers
        assert_equal "application/fhir+json", response.media_type
      end
    end
  end
end
