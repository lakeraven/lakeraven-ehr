# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ConditionsControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_smart_auth
      end

      teardown do
        teardown_smart_auth
      end

      test "GET /Condition?patient=1 returns FHIR Bundle" do
        get "/lakeraven-ehr/Condition", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
        assert_equal "searchset", body["type"]
      end

      test "search without patient param returns 400" do
        get "/lakeraven-ehr/Condition", headers: @headers
        assert_response :bad_request
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
      end

      test "entries have correct resourceType" do
        get "/lakeraven-ehr/Condition", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        entries = body["entry"]
        assert entries.any?, "seeded problem list should produce Condition entries"
        entries.each do |entry|
          assert_equal "Condition", entry.dig("resource", "resourceType")
        end
      end

      test "entries are US Core Conditions built from the seeded problem list" do
        get "/lakeraven-ehr/Condition", params: { patient: "1" }, headers: @headers
        assert_response :ok

        entries = JSON.parse(response.body)["entry"]
        assert_equal 2, entries.length

        diabetes = entries.map { |e| e["resource"] }.find { |r| r["id"] == "501" }
        assert_includes Array(diabetes.dig("meta", "profile")), Condition::US_CORE_CONDITION_PROFILE
        assert_equal "E11.9", diabetes.dig("code", "coding", 0, "code")
        assert_equal "Type 2 diabetes mellitus", diabetes.dig("code", "text")
        assert_equal "active", diabetes.dig("clinicalStatus", "coding", 0, "code")
        assert_equal "problem-list-item", diabetes.dig("category", 0, "coding", 0, "code")
        assert_equal "Patient/1", diabetes.dig("subject", "reference")

        hypertension = entries.map { |e| e["resource"] }.find { |r| r["id"] == "502" }
        assert_equal "inactive", hypertension.dig("clinicalStatus", "coding", 0, "code")
      end

      test "returns FHIR JSON content type" do
        get "/lakeraven-ehr/Condition", params: { patient: "1" }, headers: @headers
        assert_equal "application/fhir+json", response.media_type
      end

      test "accepts Patient/ prefix in patient param" do
        get "/lakeraven-ehr/Condition", params: { patient: "Patient/1" }, headers: @headers
        assert_response :ok
      end

      test "show returns 404 OperationOutcome" do
        get "/lakeraven-ehr/Condition/99999", headers: @headers
        assert_response :not_found
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "not-found", body["issue"].first["code"]
      end

      test "requires auth" do
        get "/lakeraven-ehr/Condition", params: { patient: "1" }
        assert_response :unauthorized
      end
    end
  end
end
