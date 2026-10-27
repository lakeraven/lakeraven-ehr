# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class FhirClinicalResourcesTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_smart_auth
      end

      teardown do
        teardown_smart_auth
      end

      # -- AllergyIntolerance --------------------------------------------------

      test "GET /AllergyIntolerance?patient=1 returns FHIR Bundle" do
        get "/lakeraven-ehr/AllergyIntolerance", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
        assert_equal "searchset", body["type"]
      end

      test "AllergyIntolerance search without patient returns 400" do
        get "/lakeraven-ehr/AllergyIntolerance", headers: @headers
        assert_response :bad_request
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
      end

      test "AllergyIntolerance entries have correct resourceType" do
        RpmsRpc.client.seed_keyed_collection(:allergy_list, "1", [
          { ien: 1, allergen: "Penicillin", severity: "moderate", signs: "Hives" },
          { ien: 2, allergen: "Shellfish", severity: "severe", signs: "Anaphylaxis" }
        ])

        get "/lakeraven-ehr/AllergyIntolerance", params: { patient: "1" }, headers: @headers
        body = JSON.parse(response.body)
        entries = body["entry"]
        assert entries.is_a?(Array) && entries.any?, "AllergyIntolerance bundle should include entries"
        entries.each do |entry|
          assert_equal "AllergyIntolerance", entry.dig("resource", "resourceType")
        end
      end

      # -- Condition -----------------------------------------------------------

      test "GET /Condition?patient=1 returns FHIR Bundle" do
        get "/lakeraven-ehr/Condition", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
      end

      test "Condition search without patient returns 400" do
        get "/lakeraven-ehr/Condition", headers: @headers
        assert_response :bad_request
      end

      # -- MedicationRequest ---------------------------------------------------

      test "GET /MedicationRequest?patient=1 returns FHIR Bundle" do
        get "/lakeraven-ehr/MedicationRequest", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
      end

      test "MedicationRequest search without patient returns 400" do
        get "/lakeraven-ehr/MedicationRequest", headers: @headers
        assert_response :bad_request
      end

      # -- Observation ---------------------------------------------------------

      test "GET /Observation?patient=1 returns FHIR Bundle" do
        get "/lakeraven-ehr/Observation", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
      end

      test "Observation search without patient returns 400" do
        get "/lakeraven-ehr/Observation", headers: @headers
        assert_response :bad_request
      end

      # -- Content type --------------------------------------------------------

      test "clinical resource endpoints return FHIR JSON content type" do
        get "/lakeraven-ehr/AllergyIntolerance", params: { patient: "1" }, headers: @headers
        assert_equal "application/fhir+json", response.media_type
      end

      # -- Patient/ prefix support ---------------------------------------------

      test "accepts Patient/ prefix in patient param" do
        get "/lakeraven-ehr/Condition", params: { patient: "Patient/1" }, headers: @headers
        assert_response :ok
      end

      # -- Auth required -------------------------------------------------------

      test "clinical endpoints require auth" do
        get "/lakeraven-ehr/AllergyIntolerance", params: { patient: "1" }
        assert_response :unauthorized
      end
    end
  end
end
