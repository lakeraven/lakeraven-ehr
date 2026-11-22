# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class PatientsControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper
      include BrokerStubbing

      setup do
        setup_smart_auth
      end

      teardown do
        teardown_smart_auth
      end

      test "GET /Patient/:dfn returns 200 with FHIR Patient" do
        get "/lakeraven-ehr/Patient/1", headers: @headers
        assert_response :ok
        assert_equal "application/fhir+json", response.media_type
        body = JSON.parse(response.body)
        assert_equal "Patient", body["resourceType"]
        assert_equal "1", body["id"]
      end

      test "response includes US Core profile" do
        get "/lakeraven-ehr/Patient/1", headers: @headers
        body = JSON.parse(response.body)
        assert_includes body.dig("meta", "profile"),
                        "http://hl7.org/fhir/us/core/StructureDefinition/us-core-patient"
      end

      test "response includes name family and given" do
        get "/lakeraven-ehr/Patient/1", headers: @headers
        body = JSON.parse(response.body)
        assert_equal "Anderson", body["name"].first["family"]
        assert_includes body["name"].first["given"], "Alice"
      end

      test "response includes gender and birthDate" do
        get "/lakeraven-ehr/Patient/1", headers: @headers
        body = JSON.parse(response.body)
        assert_equal "female", body["gender"]
        assert_equal "1980-05-15", body["birthDate"]
      end

      test "response includes SSN identifier" do
        get "/lakeraven-ehr/Patient/1", headers: @headers
        body = JSON.parse(response.body)
        ssn_id = body["identifier"].find { |id| id["system"]&.include?("ssn") }
        assert_equal "111-11-1111", ssn_id["value"]
      end

      test "unknown DFN returns 404 OperationOutcome" do
        get "/lakeraven-ehr/Patient/99999", headers: @headers
        assert_response :not_found
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "not-found", body["issue"].first["code"]
      end

      test "GET /Patient searches by name" do
        get "/lakeraven-ehr/Patient", params: { name: "Anderson" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
        assert_operator body["total"], :>=, 1
      end

      test "GET /Patient with no matches returns empty Bundle" do
        get "/lakeraven-ehr/Patient", params: { name: "ZZZZNONEXISTENT" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal 0, body["total"]
      end

      test "requires auth" do
        get "/lakeraven-ehr/Patient/1"
        assert_response :unauthorized
      end

      # -- Expired/revoked/invalid token auth ------------------------------------

      test "expired token returns 401" do
        expired = Doorkeeper::AccessToken.create!(
          application: @oauth_app, scopes: "system/*.read", expires_in: -1
        )
        get "/lakeraven-ehr/Patient/1",
          headers: { "Authorization" => "Bearer #{expired.plaintext_token || expired.token}" }
        assert_response :unauthorized
      end

      test "revoked token returns 401" do
        revoked = Doorkeeper::AccessToken.create!(
          application: @oauth_app, scopes: "system/*.read", expires_in: 3600
        )
        revoked.revoke
        get "/lakeraven-ehr/Patient/1",
          headers: { "Authorization" => "Bearer #{revoked.plaintext_token || revoked.token}" }
        assert_response :unauthorized
      end

      test "invalid token returns 401" do
        get "/lakeraven-ehr/Patient/1",
          headers: { "Authorization" => "Bearer totally_bogus_token" }
        assert_response :unauthorized
      end

      # -- Scope enforcement -----------------------------------------------------

      test "token without Patient read scope returns 403" do
        app = Doorkeeper::Application.create!(
          name: "scope-test", redirect_uri: "https://example.test/callback",
          scopes: "openid", confidential: true
        )
        token = Doorkeeper::AccessToken.create!(application: app, scopes: "openid", expires_in: 3600)
        get "/lakeraven-ehr/Patient/1",
          headers: { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
        assert_response :forbidden
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "forbidden", body["issue"].first["code"]
      end

      # -- Tribal affiliation is not on the egress path (#1187 / #566) -----------
      #
      # Tribal affiliation is a sovereign identifier. Until an authorization
      # gate exists (#566) no Patient egress path may emit it, and the read
      # must not even be made, whatever RPMS holds for the patient.

      test "GET /Patient/:dfn does not emit tribal affiliation or read it from RPMS" do
        calls = with_tribe_in_rpms { get "/lakeraven-ehr/Patient/1", headers: @headers }

        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Patient", body["resourceType"]
        tribal = Array(body["extension"]).select { |e| e["url"].to_s.include?("tribal-affiliation") }
        assert_empty tribal
        refute_includes response.body, "tribal-affiliation"
        refute_includes response.body, "SYNTHETIC TRIBE A"
        refute_includes response.body, "SYN-0001"
        assert_equal 0, calls, "Patient read must not call the tribal gateway"
      end

      test "GET /Patient search does not emit tribal affiliation or read it from RPMS" do
        calls = with_tribe_in_rpms do
          get "/lakeraven-ehr/Patient", params: { name: "Anderson" }, headers: @headers
        end

        assert_response :ok
        body = JSON.parse(response.body)
        assert_operator body["total"], :>=, 1
        refute_includes response.body, "tribal-affiliation"
        refute_includes response.body, "SYNTHETIC TRIBE A"
        assert_equal 0, calls, "Patient search must not call the tribal gateway"
      end

      # -- Error response structure ----------------------------------------------

      test "401 response is OperationOutcome" do
        get "/lakeraven-ehr/Patient/1"
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "login", body["issue"].first["code"]
      end

      test "404 response is OperationOutcome with not-found code" do
        get "/lakeraven-ehr/Patient/99999", headers: @headers
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "not-found", body["issue"].first["code"]
        assert_equal "error", body["issue"].first["severity"]
      end

      test "FHIR content type on 401 responses" do
        get "/lakeraven-ehr/Patient/1"
        assert_equal "application/fhir+json", response.media_type
      end

      test "FHIR content type on 404 responses" do
        get "/lakeraven-ehr/Patient/99999", headers: @headers
        assert_equal "application/fhir+json", response.media_type
      end

      private

      # Runs the block with the tribal gateway answering a synthetic tribe and
      # enrollment for every patient; returns how many gateway reads were made.
      def with_tribe_in_rpms
        gw = TribalEnrollmentGateway
        calls = 0
        stubs = {
          enrollment_details: ->(*) { calls += 1; { enrollment_number: "SYN-0001", tribe_ien: 9001, tribe_name: "SYNTHETIC TRIBE A" } },
          tribe_info: ->(*) { calls += 1; { ien: 9001, name: "SYNTHETIC TRIBE A", code: "901" } }
        }
        originals = stubs.keys.to_h { |name| [ name, gw.method(name) ] }
        stubs.each { |name, fn| gw.define_singleton_method(name) { |*args| fn.call(*args) } }
        yield
        calls
      ensure
        originals&.each { |name, meth| gw.define_singleton_method(name, meth) }
      end
    end
  end
end
