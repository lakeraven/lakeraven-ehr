# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ObservationsControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_smart_auth
      end

      teardown do
        teardown_smart_auth
      end

      test "GET /Observation?patient=1 returns FHIR Bundle" do
        get "/lakeraven-ehr/Observation", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
        assert_equal "searchset", body["type"]
      end

      test "search without patient param returns 400" do
        get "/lakeraven-ehr/Observation", headers: @headers
        assert_response :bad_request
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
      end

      test "entries have correct resourceType" do
        get "/lakeraven-ehr/Observation", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        body["entry"]&.each do |entry|
          assert_equal "Observation", entry.dig("resource", "resourceType")
        end
      end

      test "returns FHIR JSON content type" do
        get "/lakeraven-ehr/Observation", params: { patient: "1" }, headers: @headers
        assert_equal "application/fhir+json", response.media_type
      end

      test "accepts Patient/ prefix in patient param" do
        get "/lakeraven-ehr/Observation", params: { patient: "Patient/1" }, headers: @headers
        assert_response :ok
      end

      test "category=laboratory returns only laboratory observations" do
        get "/lakeraven-ehr/Observation", params: { patient: "1", category: "laboratory" }, headers: @headers
        assert_response :ok

        entries = JSON.parse(response.body)["entry"]
        assert entries.any?
        entries.each do |entry|
          assert_equal "laboratory", entry.dig("resource", "category", 0, "coding", 0, "code")
        end
        assert entries.any? { |entry| Array(entry.dig("resource", "meta", "profile")).include?(Observation::US_CORE_LAB_PROFILE) }
      end

      test "code filter returns matching laboratory observation" do
        get "/lakeraven-ehr/Observation", params: { patient: "1", code: "718-7" }, headers: @headers
        assert_response :ok

        entries = JSON.parse(response.body)["entry"]
        assert_equal 1, entries.length
        assert_equal "718-7", entries.first.dig("resource", "code", "coding", 0, "code")
      end

      test "show returns 404 OperationOutcome" do
        get "/lakeraven-ehr/Observation/99999", headers: @headers
        assert_response :not_found
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "not-found", body["issue"].first["code"]
      end

      test "requires auth" do
        get "/lakeraven-ehr/Observation", params: { patient: "1" }
        assert_response :unauthorized
      end
    end
  end
end
