# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class EncountersControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_internal_smart_auth
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
          scopes: "system/Encounter.read", confidential: true,
          organization_id: "rpms-organization-7819"
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

      # -- Store-backed encounters: show, date search, sort ----------------------

      def seed_store_encounters
        EncounterStore.instance.add(Encounter.new(
          fhir_id: "enc-1-1", patient_identifier: "1", status: "finished",
          class_code: "AMB", period_start: DateTime.new(2026, 8, 12, 9, 0, 0),
          practitioner_identifier: "101",
          reason_code: "E11.9", reason_display: "Type 2 diabetes follow-up"
        ))
        EncounterStore.instance.add(Encounter.new(
          fhir_id: "enc-1-2", patient_identifier: "1", status: "finished",
          class_code: "AMB", period_start: DateTime.new(2026, 2, 10, 9, 0, 0)
        ))
      end

      test "index serves store-backed encounters with class, period, participant, reasonCode" do
        seed_store_encounters
        get "/lakeraven-ehr/Encounter", params: { patient: "1" }, headers: @headers
        body = JSON.parse(response.body)
        enc = body["entry"].map { |e| e["resource"] }.find { |r| r["id"] == "enc-1-1" }
        assert_equal "AMB", enc.dig("class", "code")
        assert enc.dig("period", "start").start_with?("2026-08-12")
        assert_equal "Practitioner/101", enc.dig("participant", 0, "individual", "reference")
        assert_equal "Type 2 diabetes follow-up", enc.dig("reasonCode", 0, "text")
      ensure
        EncounterStore.reset_instance!
      end

      test "date=ge filter and _sort=-date order on period.start" do
        seed_store_encounters
        get "/lakeraven-ehr/Encounter",
          params: { patient: "1", date: "ge2026-08-01", _sort: "-date" }, headers: @headers
        body = JSON.parse(response.body)
        assert_equal [ "enc-1-1" ], body["entry"].map { |e| e.dig("resource", "id") }

        get "/lakeraven-ehr/Encounter", params: { patient: "1", _sort: "-date" }, headers: @headers
        ids = JSON.parse(response.body)["entry"].map { |e| e.dig("resource", "id") }
        assert_equal "enc-1-1", ids.first
      ensure
        EncounterStore.reset_instance!
      end

      test "show returns a store-backed encounter" do
        seed_store_encounters
        get "/lakeraven-ehr/Encounter/enc-1-1", headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Encounter", body["resourceType"]
        assert_equal "enc-1-1", body["id"]
      ensure
        EncounterStore.reset_instance!
      end

      test "show returns 404 for an unknown encounter" do
        get "/lakeraven-ehr/Encounter/enc-404", headers: @headers
        assert_response :not_found
        assert_equal "OperationOutcome", JSON.parse(response.body)["resourceType"]
      end

      # Guards review finding: appointment-derived encounters emitted ids in
      # search that show could not resolve. Every id a search returns must
      # be readable.
      test "every id returned by search is readable via show (store and appointment-derived)" do
        seed_store_encounters
        RpmsRpc.client.seed_keyed_collection(:patient_appointments, "1", [
          { datetime: DateTime.new(2026, 8, 12, 9, 0, 0), location_ien: 1,
            location: "Primary Care Clinic", status: "CHECKED OUT" }
        ])

        get "/lakeraven-ehr/Encounter", params: { patient: "1" }, headers: @headers
        ids = JSON.parse(response.body)["entry"].map { |e| e.dig("resource", "id") }
        assert ids.any? { |id| id.start_with?("appt-1-") }, "expected an appointment-derived id in #{ids}"
        assert_includes ids, "enc-1-1"

        ids.each do |id|
          get "/lakeraven-ehr/Encounter/#{id}", headers: @headers
          assert_response :ok
          body = JSON.parse(response.body)
          assert_equal "Encounter", body["resourceType"]
          assert_equal id, body["id"]
        end
      ensure
        RpmsRpc.client.seed_keyed_collection(:patient_appointments, "1", [])
        EncounterStore.reset_instance!
      end

      # Guards review finding: a resolved foreign appointment-derived
      # encounter must be a 403, like a store-backed one.
      test "org-bound credential gets 403 for a foreign appointment-derived encounter id" do
        RpmsRpc.client.seed_keyed_collection(:patient_appointments, "999999", [
          { datetime: DateTime.new(2026, 8, 12, 9, 0, 0), status: "CHECKED OUT" }
        ])
        # Discover the emitted id with an unbound internal credential, then
        # prove the org-bound credential cannot read it.
        get "/lakeraven-ehr/Encounter", params: { patient: "999999" }, headers: @headers
        foreign_id = JSON.parse(response.body)["entry"]
          .map { |e| e.dig("resource", "id") }.find { |id| id.start_with?("appt-999999-") }
        assert foreign_id

        teardown_smart_auth
        setup_smart_auth(scopes: "system/Encounter.read")

        get "/lakeraven-ehr/Encounter/#{foreign_id}", headers: @headers
        assert_response :forbidden
      ensure
        RpmsRpc.client.seed_keyed_collection(:patient_appointments, "999999", [])
      end

      test "org-bound credential reads its own patient's encounter but not a foreign one" do
        seed_store_encounters
        EncounterStore.instance.add(Encounter.new(
          fhir_id: "enc-foreign", patient_identifier: "999999", status: "finished", class_code: "AMB"
        ))
        teardown_smart_auth
        setup_smart_auth(scopes: "system/Encounter.read")

        get "/lakeraven-ehr/Encounter/enc-1-1", headers: @headers
        assert_response :ok

        get "/lakeraven-ehr/Encounter/enc-foreign", headers: @headers
        assert_response :forbidden
      ensure
        EncounterStore.reset_instance!
      end
    end
  end
end
