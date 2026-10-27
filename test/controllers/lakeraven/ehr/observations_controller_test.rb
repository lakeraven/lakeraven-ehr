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
        entries = body["entry"]
        assert entries.is_a?(Array) && entries.any?, "Observation bundle should include entries"
        entries.each do |entry|
          assert_equal "Observation", entry.dig("resource", "resourceType")
        end
      end

      # ORQQVI VITALS piece 1 is the V MEASUREMENT IEN (:measurement_ien since
      # rpms-rpc #188); a vital read from RPMS keeps it as its id.
      test "a vital read from RPMS carries its V MEASUREMENT IEN as its id" do
        get "/lakeraven-ehr/Observation", params: { patient: "1" }, headers: @headers
        assert_response :ok

        ids = JSON.parse(response.body)["entry"].map { |entry| entry.dig("resource", "id") }
        assert_includes ids, "1001"
      end

      test "returns FHIR JSON content type" do
        get "/lakeraven-ehr/Observation", params: { patient: "1" }, headers: @headers
        assert_equal "application/fhir+json", response.media_type
      end

      test "accepts Patient/ prefix in patient param" do
        get "/lakeraven-ehr/Observation", params: { patient: "Patient/1" }, headers: @headers
        assert_response :ok
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
