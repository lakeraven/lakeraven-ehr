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
        RpmsRpc.client.seed_keyed_collection(:problem_list, "1", [
          { ien: 1, status: "A", icd_code: "E11.9", description: "Type 2 diabetes mellitus" }
        ])

        get "/lakeraven-ehr/Condition", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        entries = body["entry"]
        assert entries.is_a?(Array) && entries.any?, "Condition bundle should include entries"
        entries.each do |entry|
          assert_equal "Condition", entry.dig("resource", "resourceType")
        end
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
