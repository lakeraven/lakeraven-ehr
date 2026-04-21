# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class AuditLoggingTest < ActionDispatch::IntegrationTest
      setup do
        AuditEvent.delete_all
        @oauth_app = Doorkeeper::Application.create!(
          name: "test", redirect_uri: "https://example.test/callback",
          scopes: "system/Patient.read", confidential: true
        )
        token = Doorkeeper::AccessToken.create!(
          application: @oauth_app, scopes: "system/Patient.read", expires_in: 3600
        )
        @headers = { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
      end

      teardown do
        AuditEvent.delete_all
        Doorkeeper::AccessToken.delete_all
        Doorkeeper::Application.delete_all
      end

      test "successful GET produces an AuditEvent" do
        assert_difference -> { AuditEvent.count }, 1 do
          get "/lakeraven-ehr/Patient/1", headers: @headers
        end

        event = AuditEvent.recent.first
        assert_equal "rest", event.event_type
        assert_equal "R", event.action
        assert_equal "0", event.outcome
        assert_equal "Patient", event.entity_type
        assert_equal "1", event.entity_identifier
        assert_equal "Application", event.agent_who_type
        assert_equal @oauth_app.uid, event.agent_who_identifier
      end

      test "404 response produces an AuditEvent with minor-failure outcome" do
        assert_difference -> { AuditEvent.count }, 1 do
          get "/lakeraven-ehr/Patient/99999", headers: @headers
        end

        event = AuditEvent.recent.first
        assert_equal "4", event.outcome
      end

      test "401 auth failure does NOT produce an AuditEvent" do
        assert_no_difference -> { AuditEvent.count } do
          get "/lakeraven-ehr/Patient/1"
        end
      end
    end
  end
end
