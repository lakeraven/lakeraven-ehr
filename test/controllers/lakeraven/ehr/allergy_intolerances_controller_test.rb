# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class AllergyIntolerancesControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_smart_auth
      end

      teardown do
        teardown_smart_auth
      end

      test "GET /AllergyIntolerance?patient=1 returns FHIR Bundle" do
        get "/lakeraven-ehr/AllergyIntolerance", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
        assert_equal "searchset", body["type"]
      end

      test "search without patient param returns 400" do
        get "/lakeraven-ehr/AllergyIntolerance", headers: @headers
        assert_response :bad_request
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
      end

      test "entries have correct resourceType" do
        get "/lakeraven-ehr/AllergyIntolerance", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        entries = body["entry"]
        assert entries.any?, "seeded allergy list should produce AllergyIntolerance entries"
        entries.each do |entry|
          assert_equal "AllergyIntolerance", entry.dig("resource", "resourceType")
        end
      end

      test "entries are US Core AllergyIntolerances built from the seeded allergy list" do
        get "/lakeraven-ehr/AllergyIntolerance", params: { patient: "1" }, headers: @headers
        assert_response :ok

        entries = JSON.parse(response.body)["entry"]
        assert_equal 2, entries.length

        penicillin = entries.map { |e| e["resource"] }.find { |r| r["id"] == "701" }
        assert_includes Array(penicillin.dig("meta", "profile")), AllergyIntolerance::US_CORE_ALLERGY_PROFILE
        assert_equal "PENICILLIN", penicillin.dig("code", "text")
        assert_equal "Patient/1", penicillin.dig("patient", "reference")
        assert_equal "HIVES", penicillin.dig("reaction", 0, "manifestation", 0, "text")
        assert_equal "moderate", penicillin.dig("reaction", 0, "severity")
        assert_equal "active", penicillin.dig("clinicalStatus", "coding", 0, "code")
      end

      test "returns FHIR JSON content type" do
        get "/lakeraven-ehr/AllergyIntolerance", params: { patient: "1" }, headers: @headers
        assert_equal "application/fhir+json", response.media_type
      end

      test "accepts Patient/ prefix in patient param" do
        get "/lakeraven-ehr/AllergyIntolerance", params: { patient: "Patient/1" }, headers: @headers
        assert_response :ok
      end

      test "show returns 404 OperationOutcome" do
        get "/lakeraven-ehr/AllergyIntolerance/99999", headers: @headers
        assert_response :not_found
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "not-found", body["issue"].first["code"]
      end

      test "requires auth" do
        get "/lakeraven-ehr/AllergyIntolerance", params: { patient: "1" }
        assert_response :unauthorized
      end
    end
  end
end
