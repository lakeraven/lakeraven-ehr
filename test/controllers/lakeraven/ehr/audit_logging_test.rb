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
        assert_equal VistaRpc::PhiSanitizer.hash_identifier("1"), event.entity_identifier
        assert_equal "Application", event.agent_who_type
        assert_equal @oauth_app.uid, event.agent_who_identifier
        assert_equal "rpms", event.backend_identifier
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

      test "entity identifier is hashed, not stored as raw DFN" do
        get "/lakeraven-ehr/Patient/1", headers: @headers

        event = AuditEvent.recent.first
        refute_equal "1", event.entity_identifier
        refute_nil event.entity_identifier
        assert_equal VistaRpc::PhiSanitizer.hash_identifier("1"), event.entity_identifier
      end

      test "backend identifier is recorded for VistA Patient read" do
        Lakeraven::EHR.configure { |c| c.backend = :vista }
        Lakeraven::EHR::Backend.reset!

        get "/lakeraven-ehr/Patient/1", headers: @headers

        event = AuditEvent.recent.first
        assert_equal "vista", event.backend_identifier
        assert_equal "Patient", event.entity_type
        assert_equal VistaRpc::PhiSanitizer.hash_identifier("1"), event.entity_identifier
      ensure
        Lakeraven::EHR.configure { |c| c.backend = :rpms }
        Lakeraven::EHR::Backend.reset!
      end

      test "VistA Practitioner read logs with hashed IEN and backend identifier" do
        Lakeraven::EHR.configure { |c| c.backend = :vista }
        Lakeraven::EHR::Backend.reset!
        setup_smart_auth(scopes: "system/Practitioner.read")

        assert_difference -> { AuditEvent.count }, 1 do
          get "/lakeraven-ehr/Practitioner/101", headers: @headers
        end

        event = AuditEvent.recent.first
        assert_equal "vista", event.backend_identifier
        assert_equal "Practitioner", event.entity_type
        assert_equal VistaRpc::PhiSanitizer.hash_identifier("101"), event.entity_identifier
      ensure
        Lakeraven::EHR.configure { |c| c.backend = :rpms }
        Lakeraven::EHR::Backend.reset!
      end

      test "VistA Patient search logs backend identifier without raw search terms" do
        Lakeraven::EHR.configure { |c| c.backend = :vista }
        Lakeraven::EHR::Backend.reset!

        assert_difference -> { AuditEvent.count }, 1 do
          get "/lakeraven-ehr/Patient", params: { name: "DOE" }, headers: @headers
        end

        event = AuditEvent.recent.first
        assert_equal "vista", event.backend_identifier
        assert_equal "Patient", event.entity_type
        assert_nil event.entity_identifier
      ensure
        Lakeraven::EHR.configure { |c| c.backend = :rpms }
        Lakeraven::EHR::Backend.reset!
      end
    end
  end
end
