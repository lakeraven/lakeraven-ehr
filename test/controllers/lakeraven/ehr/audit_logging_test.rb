# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class AuditLoggingTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        AuditEvent.delete_all
        setup_smart_auth(scopes: "system/Patient.read")
      end

      teardown do
        AuditEvent.delete_all
        teardown_smart_auth
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

      # This used to assert the opposite, and the opposite was the defect: a
      # rejected credential is exactly the event §164.312(b) wants on the
      # record. It is audited as UNATTRIBUTED — there is no identity to name —
      # which is worth more than either silence or a misattribution.
      test "401 auth failure produces an unattributed AuditEvent" do
        assert_difference -> { AuditEvent.count }, 1 do
          get "/lakeraven-ehr/Patient/1"
        end

        event = AuditEvent.recent.first
        assert_equal "4", event.outcome
        assert_equal "Unknown", event.agent_who_type
        assert_nil event.agent_who_identifier
      end
    end
  end
end
